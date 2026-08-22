import Testing
import Foundation
@testable import SpeechLocalCore

private let sampleRate = 16_000.0

/// A tone, so pitch can be measured on the way out.
private func tone(hz: Double, seconds: Double) -> [Float] {
    (0..<Int(seconds * sampleRate)).map {
        Float(sin(2 * .pi * hz * Double($0) / sampleRate))
    }
}

/// Frequency by zero crossings — enough to tell 440 Hz from 220 Hz.
private func frequency(of samples: [Float]) -> Double {
    guard samples.count > 1 else { return 0 }
    var crossings = 0
    for index in 1..<samples.count where
        (samples[index - 1] < 0) != (samples[index] < 0) { crossings += 1 }
    let seconds = Double(samples.count) / sampleRate
    return Double(crossings) / 2 / seconds
}

@Test func normalSpeedNeedsNoCorrector() {
    // Running audio through a stretcher that is not stretching only adds
    // latency and a failure mode.
    #expect(SpeedCorrector.make(rate: 1) == nil)
    #expect(SpeedCorrector.make(rate: 1.0) == nil)
}

@Test func doubleSpeedIsStretchedBackToLength() throws {
    let corrector = try #require(SpeedCorrector.make(rate: 2))
    let input = tone(hz: 440, seconds: 1)
    let output = corrector.process(input)

    let ratio = Double(output.count) / Double(input.count)
    #expect(ratio > 1.8 && ratio < 2.2, "expected ~2x the samples, got \(ratio)x")
}

@Test func stretchingLeavesThePitchAlone() throws {
    // The whole reason this is a time-stretch and not a resample. A player
    // speeding video up preserves pitch, so undoing it must too — resampling
    // would hand the recognizer a 220 Hz baritone.
    let corrector = try #require(SpeedCorrector.make(rate: 2))
    let input = tone(hz: 440, seconds: 1)
    let output = corrector.process(input)

    let heard = frequency(of: Array(output.dropFirst(2_000).dropLast(2_000)))
    #expect(abs(heard - 440) < 40, "pitch should survive the stretch, got \(heard) Hz")
}

@Test func oneAndAHalfTimesWorksToo() throws {
    let corrector = try #require(SpeedCorrector.make(rate: 1.5))
    let output = corrector.process(tone(hz: 440, seconds: 1))
    let ratio = Double(output.count) / sampleRate
    #expect(ratio > 1.35 && ratio < 1.65, "expected ~1.5s of audio, got \(ratio)s")
}

@Test func chunksJoinWithoutLosingAudio() throws {
    // A session feeds it a second at a time for an hour. Each chunk must come
    // back whole — a stretcher reset per chunk would drop a seam into every
    // second, which is where the words are.
    let corrector = try #require(SpeedCorrector.make(rate: 2))
    var total = 0
    for _ in 0..<5 {
        total += corrector.process(tone(hz: 440, seconds: 1)).count
    }
    let seconds = Double(total) / sampleRate
    #expect(seconds > 9 && seconds < 11, "5s at 2x should stretch to ~10s, got \(seconds)s")
}

@Test func silenceInSilenceOut() throws {
    let corrector = try #require(SpeedCorrector.make(rate: 2))
    #expect(corrector.process([]).isEmpty)
}

@Test func theRatesOfferedAreOnesAPlayerActuallyHas() {
    #expect(SpeedCorrector.supportedRates.first == 1)
    #expect(SpeedCorrector.supportedRates.contains(2))
    #expect(SpeedCorrector.supportedRates.allSatisfy { $0 >= 1 && $0 <= 2 })
}
