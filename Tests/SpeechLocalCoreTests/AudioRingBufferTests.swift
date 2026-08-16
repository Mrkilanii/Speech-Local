import Testing
@testable import SpeechLocalCore

/// These exist because a real 32.77 s paragraph silently lost its opening: the
/// ring is 30 s rounded up to a power of two (32.768 s), and the producer lapped
/// the consumer mid-sentence. Nothing in the suite covered capacity at the time.

private func write(_ buffer: AudioRingBuffer, count: Int, value: Float = 0.5) {
    let samples = [Float](repeating: value, count: count)
    samples.withUnsafeBufferPointer { buffer.write($0) }
}

@Test func readsBackExactlyWhatWasWritten() {
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 10, value: 0.25)
    let (samples, next) = buffer.read(from: 0)
    #expect(samples.count == 10)
    #expect(samples.allSatisfy { $0 == 0.25 })
    #expect(next == 10)
}

@Test func cursorAdvancesAcrossSuccessiveReads() {
    // The drain loop depends on this: each tick must return only what is new.
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 10)
    let (first, cursor) = buffer.read(from: 0)
    write(buffer, count: 5)
    let (second, _) = buffer.read(from: cursor)
    #expect(first.count == 10)
    #expect(second.count == 5, "a second read must not repeat the first")
}

@Test func readReturnsNothingWhenNoNewAudio() {
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 10)
    let (_, cursor) = buffer.read(from: 0)
    let (again, _) = buffer.read(from: cursor)
    #expect(again.isEmpty)
}

// MARK: - Capacity

@Test func detectsOverrunWhenProducerLapsConsumer() {
    // The exact failure: keep writing without draining and the oldest audio is
    // gone. Capacity rounds up to a power of two, so 100 samples/s for 1 s
    // gives 128.
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 200)
    #expect(buffer.hasOverrun(cursor: 0), "overrun must be detectable, not silent")
}

@Test func noOverrunWhenDrainedRegularly() {
    // What the drain loop is for: read often enough and nothing is ever lost.
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    var cursor: UInt64 = 0
    var total = 0
    for _ in 0..<20 {
        write(buffer, count: 50)          // more than capacity in aggregate
        #expect(!buffer.hasOverrun(cursor: cursor), "draining must prevent overrun")
        let (samples, next) = buffer.read(from: cursor)
        total += samples.count
        cursor = next
    }
    #expect(total == 1000, "every sample must survive when drained")
}

@Test func overrunReturnsSurvivingAudioRatherThanGarbage() {
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 300)
    let (samples, _) = buffer.read(from: 0)
    // Capacity is 128; the stale request is clamped to what still exists.
    #expect(samples.count <= 128)
    #expect(!samples.isEmpty)
}

// MARK: - Preroll

@Test func snapshotReturnsTheMostRecentAudio() {
    // Preroll: the hotkey is recognised after speech has begun, so the buffer
    // must be able to look backwards.
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 50, value: 0.1)
    write(buffer, count: 50, value: 0.9)
    let recent = buffer.snapshot(lastSeconds: 0.5)
    #expect(recent.count == 50)
    #expect(recent.allSatisfy { $0 == 0.9 }, "snapshot must return the newest audio")
}

@Test func snapshotClampsToWhatExists() {
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)
    write(buffer, count: 20)
    #expect(buffer.snapshot(lastSeconds: 10).count == 20)
}

@Test func snapshotOfEmptyBufferIsEmpty() {
    #expect(AudioRingBuffer(seconds: 1, sampleRate: 100).snapshot(lastSeconds: 1).isEmpty)
}

// MARK: - Wrapping correctness

@Test func wrappedReadsPreserveOrder() {
    // A read spanning the wrap point must not scramble the audio.
    let buffer = AudioRingBuffer(seconds: 1, sampleRate: 100)   // capacity 128
    write(buffer, count: 120, value: 0.1)
    let (_, cursor) = buffer.read(from: 0)
    write(buffer, count: 20, value: 0.9)                        // wraps
    let (samples, _) = buffer.read(from: cursor)
    #expect(samples.count == 20)
    #expect(samples.allSatisfy { $0 == 0.9 }, "wrapped read returned stale samples")
}
