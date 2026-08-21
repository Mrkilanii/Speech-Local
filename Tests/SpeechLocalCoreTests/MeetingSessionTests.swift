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

// MARK: - The loop

@Test func transcriptAccumulatesWhileAudioArrives() async throws {
    let buffer = ring()
    let engine = StubASR()
    let session = MeetingSession(engine: engine, buffer: buffer, locale: "en-US")

    await session.start()
    #expect(await session.currentPhase == .recording)

    for _ in 0..<3 {
        write(buffer, seconds: 0.5)
        try await Task.sleep(for: .milliseconds(1_100))
    }
    await session.stop()

    #expect(await session.currentPhase == .done)
    #expect(await session.transcript.contains("chunk1"))
    let seen = await engine.seen()
    #expect(seen.chunks >= 3, "every drain should reach the recognizer")
    #expect(seen.samples >= 24_000, "1.5 s of audio should arrive, got \(seen.samples)")
}

@Test func theSessionKeepsNoAudio() async throws {
    // The whole point: an hour must cost what its transcript costs. A minute
    // of audio is 960,000 samples; the session must be holding none of them.
    let buffer = ring()
    let session = MeetingSession(engine: StubASR(), buffer: buffer, locale: "en-US")
    await session.start()
    write(buffer, seconds: 4)
    try await Task.sleep(for: .milliseconds(1_100))
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
    try await Task.sleep(for: .milliseconds(1_100))
    await session.stop()

    #expect(await session.didLoseAudio, "an overrun must be reported")
}
