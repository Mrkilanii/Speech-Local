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
    private var text = ""
    private var startedAt: Date?
    private var endedAt: Date?
    private var pump: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var feed: AsyncStream<AudioChunk>.Continuation?
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
    public var transcript: String { text }
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

        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        feed = continuation

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

                var samples = speed == nil ? mic : []
                if let systemBuffer {
                    if systemBuffer.hasOverrun(cursor: systemCursor) {
                        await self?.noteOverrun()
                        systemCursor = systemBuffer.writeCursor
                    }
                    let (system, systemNext) = systemBuffer.read(from: systemCursor)
                    systemCursor = systemNext
                    // Only the playback was sped up, so only it is stretched —
                    // and at that point the microphone is not in the mix.
                    samples = Self.mix(samples, speed.map { $0.process(system) } ?? system)
                }

                guard !samples.isEmpty else { continue }
                await self?.noteRead(samples.count)
                continuation.yield(AudioChunk(samples: samples))
            }
        }

        reader = Task { [weak self] in
            guard let self else { return }
            do {
                for try await partial in await self.engine.transcribe(
                    audio: stream, locale: self.locale, biasTerms: self.biasTerms
                ) {
                    await self.replaceTranscript(partial)
                }
                await self.settle(nil)
            } catch {
                await self.settle("\(error)")
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
        feed?.finish()
        feed = nil

        await reader?.value
        reader = nil
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

    /// Sums the microphone and the room into one stream.
    ///
    /// Both arrive at 16 kHz from the same wall clock, so they are aligned to
    /// within a drain's jitter — close enough for a recognizer, which is the
    /// only consumer. The lengths still differ tick to tick, so the shorter is
    /// summed against the longer and the remainder carried through: a source
    /// that stalls or was never granted degrades to the other rather than
    /// truncating the meeting to its length.
    ///
    /// Clamped, because two loud sources add past full scale and a recognizer
    /// hears clipping as noise.
    static func mix(_ first: [Float], _ second: [Float]) -> [Float] {
        if second.isEmpty { return first }
        if first.isEmpty { return second }

        let overlap = min(first.count, second.count)
        var out = first.count >= second.count ? first : second
        for index in 0..<overlap {
            out[index] = max(-1, min(1, first[index] + second[index]))
        }
        return out
    }

    // MARK: - Bookkeeping

    private func replaceTranscript(_ partial: String) {
        // The engine emits the transcript so far, not deltas.
        text = partial
    }

    private func noteRead(_ count: Int) { samplesRead += count }

    private func noteOverrun() { overran = true }

    /// The recognizer's stream ended, either because the feed closed or
    /// because it gave up. A failure outranks a clean finish.
    private func settle(_ error: String?) {
        if let error {
            phase = .failed(error)
            endedAt = endedAt ?? Date()
        } else if phase != .done {
            phase = .done
        }
    }
}
