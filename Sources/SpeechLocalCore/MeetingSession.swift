import Foundation

/// One recorded meeting: audio in, transcript out, for as long as it runs.
///
/// The dictation path holds its whole recording in memory as `[Float]` and is
/// capped at five minutes for that reason — an hour would be 230 MB of samples
/// before anything else. A meeting cannot work that way, so this keeps no audio
/// at all. It lifts each second off the capture ring, hands it straight to the
/// recognizer, and lets it go; only the transcript grows, and text is cheap.
///
/// That is what the streaming half of `ASREngine` was written for. It has been
/// there, documented as existing so "a long hands-free session cannot grow
/// without bound in memory", with nothing calling it. This is the caller.
///
/// **Two recognizers, not one mix.** The microphone and the system audio used
/// to be summed into one stream, which lost who said what. Each now has its own
/// streaming recognizer, and the transcript is their segments interleaved by
/// time as "You" and "Them" turns (`SpeakerTurns`). The system-audio
/// recognizer starts only when the tap first delivers audio: an in-person
/// meeting, where nothing plays, runs one recognizer and reads exactly as it
/// did before. Still no audio is kept — each second goes to its own
/// recognizer and is let go.
///
/// **Deliberately not a third `CleanupMode`.** That type is a dictionary key in
/// `HotkeyManager`'s bindings and gestures, in the dictation session store, in
/// `Settings.isValid` and `resolvingConflicts`, and it drives two settings
/// pickers and three menu labels. A meeting is started from a window rather
/// than a held key, so it never needs to be one, and making it one would touch
/// all of that for nothing.
public actor MeetingSession {
    public enum Phase: Sendable, Equatable {
        case idle
        case recording
        /// Still running, still holding the recognizer open, but skipping the
        /// audio. A course has interruptions and they do not belong in the note.
        case paused
        case finishing
        /// The session is over and the note is being written. Owned by the
        /// caller rather than reached from here: the recorder's job ends when
        /// the audio does.
        case summarising
        case done
        case failed(String)
    }

    /// How often audio is lifted off the ring. The ring holds ~32 s, so this
    /// has a wide margin, and matches the dictation drain that is known to keep
    /// up.
    static let drainInterval = Duration.seconds(1)

    private let engine: any ASREngine
    private let buffer: AudioRingBuffer
    /// The other side of the call, when system audio is being captured. Absent
    /// is a working configuration, not a failure: it is what the app does today
    /// and what it falls back to when the tap is refused.
    private let systemBuffer: AudioRingBuffer?
    private let locale: String
    /// Undoes sped-up playback before the recognizer hears it. Nil at 1x.
    private let speed: SpeedCorrector?
    private let biasTerms: [String]

    private var phase: Phase = .idle
    private var startedAt: Date?
    private var endedAt: Date?
    private var pump: Task<Void, Never>?
    private var readers: [Task<Void, Never>] = []
    private var micFeed: AsyncStream<AudioChunk>.Continuation?
    /// Opened on the first audio the tap delivers, not before.
    private var systemFeed: AsyncStream<AudioChunk>.Continuation?
    /// What each recognizer has reported, on its own clock. Replaced wholesale
    /// on every result: the engine reports everything so far, not deltas.
    private var micSegments: [TimedSegment] = []
    private var systemSegments: [TimedSegment] = []
    /// Each recognizer's clock mapped onto the meeting's.
    private var micTimeline = SourceTimeline()
    private var systemTimeline = SourceTimeline()
    /// Samples seen but not yet handed over, for the record — never the audio.
    private var samplesRead = 0
    private var overran = false
    /// Time spent paused, subtracted from the length so a meeting reads as
    /// what was recorded rather than how long the window was open.
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    /// - Parameter playbackRate: what the system audio is playing at. Above 1
    ///   the microphone is dropped: only the playback was sped up, and
    ///   stretching a mix would slow the speaker's own voice to half pace.
    ///   Someone recording a course at 2x is not also in a conversation.
    public init(engine: any ASREngine, buffer: AudioRingBuffer,
                systemBuffer: AudioRingBuffer? = nil,
                locale: String, biasTerms: [String] = [],
                playbackRate: Double = 1) {
        self.engine = engine
        self.speed = SpeedCorrector.make(rate: playbackRate)
        self.buffer = buffer
        self.systemBuffer = systemBuffer
        self.locale = locale
        self.biasTerms = biasTerms
    }

    // MARK: - Reading the state

    public var currentPhase: Phase { phase }

    /// Both sides interleaved into turns, or one side unlabelled when only one
    /// has said anything. Rebuilt on each read, which is a pass over text.
    public var transcript: String {
        SpeakerTurns.render(you: micTimeline.place(micSegments),
                            them: systemTimeline.place(systemSegments))
    }

    /// Seconds of system audio handed to its recognizer, and how many times
    /// it went quiet long enough to need re-anchoring. For the log: zero
    /// seconds is a tap that never delivered, which is not an error.
    public var systemAudioHeard: (seconds: TimeInterval, gaps: Int) {
        (Double(systemTimeline.fed) / systemTimeline.sampleRate, systemTimeline.gaps)
    }

    public var didLoseAudio: Bool { overran }

    public var elapsed: TimeInterval {
        guard let startedAt else { return 0 }
        // One `now` for both halves. Reading the clock twice made the value
        // creep by microseconds while paused, when it should be frozen.
        let now = Date()
        let paused = pausedTotal + (pausedAt.map { now.timeIntervalSince($0) } ?? 0)
        return max(0, (endedAt ?? now).timeIntervalSince(startedAt) - paused)
    }

    public var isPaused: Bool { phase == .paused }

    /// Seconds of audio actually handed to the recognizer. Diverging from
    /// `elapsed` is how a dropped stretch shows up.
    public var secondsCaptured: TimeInterval {
        Double(samplesRead) / 16_000
    }

    // MARK: - Running

    public func start() {
        guard phase == .idle else { return }
        phase = .recording
        startedAt = Date()
        endedAt = nil

        // At 2x only the playback is transcribed, so there is no microphone
        // recognizer to start.
        if speed == nil { micFeed = openFeed(for: .you) }

        // Start reading from where the ring is now: a meeting begins when the
        // user says so, not 30 seconds of whatever preceded it.
        var cursor = buffer.writeCursor
        var systemCursor = systemBuffer?.writeCursor ?? 0
        let buffer = self.buffer
        let systemBuffer = self.systemBuffer
        let speed = self.speed

        pump = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.drainInterval)
                if Task.isCancelled { break }

                // Paused: advance past whatever arrived without reading it.
                // Not reading at all would let the ring lap and report an
                // overrun, and audio deliberately skipped is not audio lost.
                if await self?.isPaused == true {
                    cursor = buffer.writeCursor
                    systemCursor = systemBuffer?.writeCursor ?? systemCursor
                    continue
                }

                if buffer.hasOverrun(cursor: cursor) {
                    await self?.noteOverrun()
                    cursor = buffer.writeCursor      // resume from the live edge
                }
                let (mic, next) = buffer.read(from: cursor)
                cursor = next

                var system: [Float] = []
                if let systemBuffer {
                    if systemBuffer.hasOverrun(cursor: systemCursor) {
                        await self?.noteOverrun()
                        systemCursor = systemBuffer.writeCursor
                    }
                    let (read, systemNext) = systemBuffer.read(from: systemCursor)
                    systemCursor = systemNext
                    // Only the playback was sped up, so only it is stretched —
                    // and at that point the microphone is not being recorded.
                    system = speed.map { $0.process(read) } ?? read
                }

                let heard = speed == nil ? mic : []
                guard !heard.isEmpty || !system.isEmpty else { continue }
                await self?.hand(mic: heard, system: system)
            }
        }
    }

    /// Stops recording and waits for the recognizer to finish the audio it has
    /// already been given. Safe to call twice.
    public func stop() async {
        if phase == .paused {
            if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
            self.pausedAt = nil
            phase = .recording          // so the guard below still admits it
        }
        guard phase == .recording else { return }
        phase = .finishing
        endedAt = Date()

        // Take the last second before closing the feed, or the tail of the
        // meeting is lost — the same order the dictation path had to learn.
        pump?.cancel()
        pump = nil
        micFeed?.finish()
        micFeed = nil
        systemFeed?.finish()
        systemFeed = nil

        // No feed can open from here on: `hand` refuses once finishing.
        let running = readers
        readers = []
        for reader in running { await reader.value }
        if phase == .finishing { phase = .done }
    }

    /// Stops taking audio without ending the meeting.
    ///
    /// The recognizer stream stays open and the transcript stays put; the pump
    /// keeps ticking so the ring cursor tracks the live edge. Tearing the
    /// recognizer down and building it again on resume would split the meeting
    /// into two transcripts and pay the analyzer's start-up cost every time.
    public func pause() {
        guard phase == .recording else { return }
        phase = .paused
        pausedAt = Date()
    }

    public func resume() {
        guard phase == .paused else { return }
        if let pausedAt { pausedTotal += Date().timeIntervalSince(pausedAt) }
        pausedAt = nil
        phase = .recording
    }

    // MARK: - Bookkeeping

    /// Starts a recognizer for one side and returns what feeds it.
    private func openFeed(for speaker: Speaker) -> AsyncStream<AudioChunk>.Continuation {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        let engine = self.engine
        let locale = self.locale
        let biasTerms = self.biasTerms
        readers.append(Task { [weak self] in
            do {
                for try await segments in engine.transcribeSegments(
                    audio: stream, locale: locale, biasTerms: biasTerms
                ) {
                    await self?.replaceSegments(segments, from: speaker)
                }
                await self?.settle(nil)
            } catch {
                await self?.settle("\(error)")
            }
        })
        return continuation
    }

    /// One drain's audio, each side to its own recognizer, stamped with the
    /// meeting time it was read at so the two can be put back in order.
    private func hand(mic: [Float], system: [Float]) {
        guard phase == .recording || phase == .paused else { return }
        let now = elapsed
        if !mic.isEmpty, let micFeed {
            micTimeline.admit(mic.count, endingAt: now)
            micFeed.yield(AudioChunk(samples: mic))
        }
        if !system.isEmpty {
            // Lazily: a tap that never delivers never costs a recognizer.
            if systemFeed == nil { systemFeed = openFeed(for: .them) }
            // At 2x this counts stretched samples, so its clock runs ahead of
            // the meeting's. Harmless: at 2x it is the only stream, and order
            // within one stream is all that is used.
            systemTimeline.admit(system.count, endingAt: now)
            systemFeed?.yield(AudioChunk(samples: system))
        }
        samplesRead += max(mic.count, system.count)
    }

    private func replaceSegments(_ segments: [TimedSegment], from speaker: Speaker) {
        switch speaker {
        case .you:  micSegments = segments
        case .them: systemSegments = segments
        }
    }

    private func noteOverrun() { overran = true }

    /// A recognizer's stream ended, either because the feed closed or because
    /// it gave up. A failure outranks a clean finish — including the other
    /// recognizer's clean finish arriving after it.
    private func settle(_ error: String?) {
        if let error {
            phase = .failed(error)
            endedAt = endedAt ?? Date()
        } else if case .failed = phase {
            return
        } else if phase != .done {
            phase = .done
        }
    }
}
