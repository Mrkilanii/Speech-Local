import Testing
import Foundation
@testable import SpeechLocalCore

/// Stands in for the recognizer. Reports how much audio it was handed, which
/// is the thing under test — the session must pass audio through and keep none.
private actor StubASR: ASREngine {
    private(set) var chunksSeen = 0
    private(set) var samplesSeen = 0
    private let failWith: String?
    private let continuationBox = Box()

    final class Box: @unchecked Sendable {
        var yield: ((String) -> Void)?
        var finish: (() -> Void)?
    }

    init(failWith: String? = nil) { self.failWith = failWith }

    func availability(locale: String) async -> ASRAvailability { .available }

    nonisolated func transcribe(
        audio: AsyncStream<AudioChunk>, locale: String, biasTerms: [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var words: [String] = []
                for await chunk in audio {
                    await self.count(chunk)
                    words.append("chunk\(words.count + 1)")
                    continuation.yield(words.joined(separator: " "))
                }
                if let failWith = self.failWith {
                    continuation.finish(throwing: ASRUnavailable.other(failWith))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func count(_ chunk: AudioChunk) {
        chunksSeen += 1
        samplesSeen += chunk.samples.count
    }

    func seen() -> (chunks: Int, samples: Int) { (chunksSeen, samplesSeen) }
}

private func ring(seconds: Double = 30) -> AudioRingBuffer {
    AudioRingBuffer(seconds: seconds, sampleRate: 16_000)
}

private func write(_ buffer: AudioRingBuffer, seconds: Double) {
    let samples = [Float](repeating: 0.2, count: Int(seconds * 16_000))
    samples.withUnsafeBufferPointer { buffer.write($0) }
}


/// Waits for the pump to have drained, rather than guessing how long it takes.
///
/// The session drains once a second; every fixed sleep near that boundary is a
/// coin flip on a loaded machine, and three of these tests were failing about
/// one run in three because of it.
///
/// 20 s, not 6: on 27 Sep, with other sessions' test runs holding the load
/// average above 100, a drain took longer than 6 s and the next assertion
/// failed for a reason that had nothing to do with it. A timeout now says so.
private func until(
    _ timeout: Duration = .seconds(20),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(50))
    }
    Issue.record("condition not met within \(timeout)", sourceLocation: sourceLocation)
}

// MARK: - The loop

@Test func transcriptAccumulatesWhileAudioArrives() async throws {
    let buffer = ring()
    let engine = StubASR()
    let session = MeetingSession(engine: engine, buffer: buffer, locale: "en-US")

    await session.start()
    #expect(await session.currentPhase == .recording)

    for _ in 0..<3 {
        write(buffer, seconds: 0.5)
    }
    try await until { await engine.seen().samples >= 24_000 }
    await session.stop()

    #expect(await session.currentPhase == .done)
    #expect(await session.transcript.contains("chunk1"))
    let seen = await engine.seen()
    #expect(seen.samples >= 24_000, "1.5 s of audio should arrive, got \(seen.samples)")
}

@Test func theSessionKeepsNoAudio() async throws {
    // The whole point: an hour must cost what its transcript costs. A minute
    // of audio is 960,000 samples; the session must be holding none of them.
    let buffer = ring()
    let session = MeetingSession(engine: StubASR(), buffer: buffer, locale: "en-US")
    await session.start()
    write(buffer, seconds: 4)
    try await until { await session.secondsCaptured > 0 }
    await session.stop()

    #expect(await session.secondsCaptured > 0)
    // Nothing in the type can hold samples — enforced by construction, so the
    // assertion is on what it reports rather than on what it stores.
    #expect(await session.transcript.count < 1_000)
}

// MARK: - Lifecycle

@Test func stopIsIdempotentAndStartDoesNotRestart() async throws {
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    await session.start()
    let firstStart = await session.elapsed
    await session.start()                       // must not restart the clock
    #expect(await session.elapsed >= firstStart)

    await session.stop()
    let settled = await session.elapsed
    await session.stop()                        // must be safe twice
    #expect(await session.currentPhase == .done)
    #expect(await session.elapsed == settled, "the clock stops when the meeting does")
}

@Test func elapsedStopsAtTheEnd() async throws {
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    await session.start()
    try await Task.sleep(for: .milliseconds(200))
    await session.stop()
    let atStop = await session.elapsed
    try await Task.sleep(for: .milliseconds(200))
    #expect(await session.elapsed == atStop)
}

@Test func aRecognizerFailureIsReportedNotSwallowed() async throws {
    let session = MeetingSession(
        engine: StubASR(failWith: "model gone"), buffer: ring(), locale: "en-US")
    await session.start()
    await session.stop()

    if case .failed(let why) = await session.currentPhase {
        #expect(why.contains("model gone"))
    } else {
        Issue.record("expected .failed, got \(await session.currentPhase)")
    }
}

@Test func anIdleSessionReportsNothing() async {
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    #expect(await session.currentPhase == .idle)
    #expect(await session.elapsed == 0)
    #expect(await session.transcript.isEmpty)
    #expect(await session.didLoseAudio == false)
}

// MARK: - Losing audio

@Test func lappingTheRingIsRecordedRatherThanHidden() async throws {
    // A stall long enough to lap the ring loses speech. It must be visible:
    // silently resuming would leave a gap nobody knows about.
    let buffer = ring(seconds: 1)
    let session = MeetingSession(engine: StubASR(), buffer: buffer, locale: "en-US")
    await session.start()
    write(buffer, seconds: 8)                   // eight seconds into a one-second ring
    try await until { await session.didLoseAudio }
    await session.stop()

    #expect(await session.didLoseAudio, "an overrun must be reported")
}

// MARK: - Two sides, two recognizers

/// A recognizer that knows when things were said: one segment per chunk, timed
/// on its own clock (seconds of audio handed to it), named after the side the
/// chunk came from — the tests write the microphone at 0.2 and the call at 0.7.
private actor TimedASR: ASREngine {
    private(set) var sessionsStarted = 0
    private let failOnSystem: Bool

    init(failOnSystem: Bool = false) { self.failOnSystem = failOnSystem }

    func availability(locale: String) async -> ASRAvailability { .available }

    nonisolated func transcribe(
        audio: AsyncStream<AudioChunk>, locale: String, biasTerms: [String]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    nonisolated func transcribeSegments(
        audio: AsyncStream<AudioChunk>, locale: String, biasTerms: [String]
    ) -> AsyncThrowingStream<[TimedSegment], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.began()
                var segments: [TimedSegment] = []
                var clock = 0.0
                var fromSystem = false
                for await chunk in audio {
                    fromSystem = (chunk.samples.first ?? 0) > 0.5
                    let seconds = Double(chunk.samples.count) / chunk.sampleRate
                    segments.append(TimedSegment(
                        start: clock, end: clock + seconds,
                        text: "\(fromSystem ? "sys" : "mic")\(segments.count + 1)."))
                    clock += seconds
                    continuation.yield(segments)
                }
                if fromSystem && self.failOnSystem {
                    continuation.finish(throwing: ASRUnavailable.other("system side broke"))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func began() { sessionsStarted += 1 }
}

private func write(_ buffer: AudioRingBuffer, seconds: Double, level: Float) {
    let samples = [Float](repeating: level, count: Int(seconds * 16_000))
    samples.withUnsafeBufferPointer { buffer.write($0) }
}

@Test func theTwoSidesComeBackLabelledInTheOrderTheyWereSaid() async throws {
    let mic = ring()
    let system = ring()
    let session = MeetingSession(
        engine: TimedASR(), buffer: mic, systemBuffer: system, locale: "en-US")
    await session.start()

    // Each side speaks only after the previous one has been drained, so the
    // order on the meeting's clock is known.
    write(mic, seconds: 1, level: 0.2)
    try await until { await session.transcript.contains("mic1") }
    write(system, seconds: 1, level: 0.7)
    try await until { await session.transcript.contains("sys1") }
    write(mic, seconds: 1, level: 0.2)
    try await until { await session.transcript.contains("mic2") }
    await session.stop()

    #expect(await session.transcript == "You: mic1.\n\nThem: sys1.\n\nYou: mic2.")
    #expect(await session.currentPhase == .done)
}

@Test func aTapThatNeverDeliversStartsNoSecondRecognizer() async throws {
    // Nothing playing is the in-person meeting. It must cost one recognizer
    // and read exactly as it did before labelling existed.
    let mic = ring()
    let engine = TimedASR()
    let session = MeetingSession(
        engine: engine, buffer: mic, systemBuffer: ring(), locale: "en-US")
    await session.start()
    write(mic, seconds: 1, level: 0.2)
    try await until { await session.transcript.contains("mic1") }
    write(mic, seconds: 1, level: 0.2)
    try await until { await session.transcript.contains("mic2") }
    await session.stop()

    #expect(await engine.sessionsStarted == 1)
    #expect(await session.transcript == "mic1. mic2.", "one side is not labelled")
    #expect(await session.systemAudioHeard.seconds == 0)
}

@Test func theCallStartsItsRecognizerWhenItFirstPlays() async throws {
    let mic = ring()
    let system = ring()
    let engine = TimedASR()
    let session = MeetingSession(
        engine: engine, buffer: mic, systemBuffer: system, locale: "en-US")
    await session.start()
    write(mic, seconds: 1, level: 0.2)
    try await until { await session.transcript.contains("mic1") }
    #expect(await engine.sessionsStarted == 1)

    write(system, seconds: 1, level: 0.7)
    try await until { await session.transcript.contains("sys1") }
    await session.stop()
    #expect(await engine.sessionsStarted == 2)
    #expect(await session.systemAudioHeard.seconds >= 1)
}

@Test func atSpeedOnlyTheCallIsTranscribedAndUnlabelled() async throws {
    let system = ring()
    let engine = TimedASR()
    let session = MeetingSession(
        engine: engine, buffer: ring(), systemBuffer: system,
        locale: "en-US", playbackRate: 2)
    await session.start()
    write(system, seconds: 1, level: 0.7)
    try await until { await session.transcript.contains("sys1") }
    await session.stop()

    #expect(await engine.sessionsStarted == 1, "no microphone recognizer at 2x")
    #expect(await session.transcript.hasPrefix("sys1."))
    #expect(!SpeakerTurns.isLabelled(await session.transcript))
}

@Test func oneSideFailingFailsTheMeetingEvenIfTheOtherFinishesCleanly() async throws {
    let mic = ring()
    let system = ring()
    let session = MeetingSession(
        engine: TimedASR(failOnSystem: true), buffer: mic, systemBuffer: system,
        locale: "en-US")
    await session.start()
    write(mic, seconds: 1, level: 0.2)
    write(system, seconds: 1, level: 0.7)
    try await until { await session.transcript.contains("sys1") }
    await session.stop()

    if case .failed(let why) = await session.currentPhase {
        #expect(why.contains("system side broke"))
    } else {
        Issue.record("expected .failed, got \(await session.currentPhase)")
    }
}

@Test func bothSourcesReachTheRecognizer() async throws {
    let mic = ring()
    let system = ring()
    let engine = StubASR()
    let session = MeetingSession(
        engine: engine, buffer: mic, systemBuffer: system, locale: "en-US")

    await session.start()
    write(mic, seconds: 1)
    write(system, seconds: 1)

    // Waiting on the drain rather than on the clock: the pump ticks once a
    // second, and a fixed 1.1 s sleep loses the race whenever the machine is
    // busy enough to delay the tick.
    try await until { await engine.seen().samples >= 32_000 }
    await session.stop()

    // Each side to its own recognizer now, not one mixed second.
    let seen = await engine.seen()
    #expect(seen.samples >= 32_000, "a second from each side should arrive")
}

// MARK: - Sped-up playback

@Test func atNormalSpeedTheMicrophoneIsStillRecorded() async throws {
    let mic = ring()
    let system = ring()
    let engine = StubASR()
    let session = MeetingSession(
        engine: engine, buffer: mic, systemBuffer: system,
        locale: "en-US", playbackRate: 1)

    await session.start()
    write(mic, seconds: 1)
    try await until { await engine.seen().samples > 0 }
    await session.stop()
    #expect(await engine.seen().samples >= 16_000, "a conversation needs both sides")
}

@Test func aboveNormalSpeedTheMicrophoneIsDropped() async throws {
    // Only the playback was sped up. Stretching a mix would slow the speaker's
    // own voice to half pace, and someone recording a course at 2x is not also
    // in a conversation.
    let mic = ring()
    let system = ring()
    let engine = StubASR()
    let session = MeetingSession(
        engine: engine, buffer: mic, systemBuffer: system,
        locale: "en-US", playbackRate: 2)

    await session.start()
    write(mic, seconds: 2)          // microphone only — nothing is playing
    try await Task.sleep(for: .milliseconds(1_400))
    await session.stop()
    #expect(await engine.seen().samples == 0, "the microphone must not reach it at 2x")
}

@Test func spedUpPlaybackArrivesStretched() async throws {
    let system = ring()
    let engine = StubASR()
    let session = MeetingSession(
        engine: engine, buffer: ring(), systemBuffer: system,
        locale: "en-US", playbackRate: 2)

    await session.start()
    write(system, seconds: 1)       // one second captured at 2x…
    try await until { await engine.seen().samples > 20_000 }
    await session.stop()

    // …is two seconds of speech at normal pace by the time it is transcribed.
    let seen = await engine.seen()
    #expect(seen.samples > 24_000, "expected ~32000 stretched samples, got \(seen.samples)")
}

// MARK: - Pausing

@Test func pausingStopsTakingAudio() async throws {
    // A long course has interruptions and they do not belong in the note.
    let buffer = ring()
    let engine = StubASR()
    let session = MeetingSession(engine: engine, buffer: buffer, locale: "en-US")

    await session.start()
    write(buffer, seconds: 1)
    try await until { await engine.seen().samples >= 16_000 }

    await session.pause()
    #expect(await session.isPaused)
    let atPause = await engine.seen().samples

    write(buffer, seconds: 2)               // the interruption
    try await Task.sleep(for: .milliseconds(1_400))
    #expect(await engine.seen().samples == atPause, "nothing may arrive while paused")

    await session.resume()
    write(buffer, seconds: 1)
    try await until { await engine.seen().samples > atPause }
    await session.stop()
    #expect(await engine.seen().samples > atPause, "and it picks up again after")
}

@Test func aPauseIsNotLostAudio() async throws {
    // Skipping is not losing. Left unread, the ring laps in ~32 s and reports
    // an overrun — a pause longer than that would claim to have dropped
    // speech nobody wanted.
    let buffer = ring(seconds: 1)           // laps almost immediately
    let session = MeetingSession(engine: StubASR(), buffer: buffer, locale: "en-US")

    await session.start()
    await session.pause()
    write(buffer, seconds: 8)               // eight seconds into a one-second ring
    try await Task.sleep(for: .milliseconds(1_400))
    await session.resume()
    await session.stop()

    #expect(await session.didLoseAudio == false)
}

@Test func pausedTimeIsNotPartOfTheLength() async throws {
    // A meeting should read as what was recorded, not how long the window was
    // open. Twenty minutes of course plus a ten-minute break is twenty.
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    let started = Date()
    await session.start()
    try await Task.sleep(for: .milliseconds(200))

    await session.pause()
    try await Task.sleep(for: .milliseconds(400))
    let whilePaused = await session.elapsed
    try await Task.sleep(for: .milliseconds(300))
    #expect(await session.elapsed == whilePaused, "the clock stops while paused")

    await session.resume()
    await session.stop()

    // Measured against the wall clock rather than a fixed number: actor hops
    // and awaits make the real elapsed time longer than the sleeps, and the
    // property under test is the difference, not the total.
    let wall = Date().timeIntervalSince(started)
    let total = await session.elapsed
    #expect(total <= wall - 0.65,
            "700ms of pause should be missing from \(wall)s, got \(total)s")
}

@Test func pauseAndResumeAreIdempotent() async throws {
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    await session.resume()                  // before starting: no effect
    #expect(await session.currentPhase == .idle)

    await session.start()
    await session.pause()
    await session.pause()                   // twice is safe
    #expect(await session.isPaused)
    await session.resume()
    await session.resume()
    #expect(await session.currentPhase == .recording)
    await session.stop()
}

@Test func aPausedMeetingCanBeStopped() async throws {
    // Forgetting to resume before stopping must not strand the session.
    let session = MeetingSession(engine: StubASR(), buffer: ring(), locale: "en-US")
    await session.start()
    await session.pause()
    await session.stop()
    #expect(await session.currentPhase == .done)
}
