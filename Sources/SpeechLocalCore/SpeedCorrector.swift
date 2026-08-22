import Foundation
import AVFoundation

/// Slows sped-up playback back to normal before the recognizer hears it.
///
/// Watching at 2× costs about 70% of the transcript. Measured on the same
/// minute of the same video: at 1× whole paragraphs come back word-perfect; at
/// 2× the same passage is "I, I, I, I, I, I, and most importantly, find find".
/// Apple's recognizer is trained on speech at speaking pace, and segmentation
/// is what breaks first.
///
/// **Time-stretch, not resampling.** A player that speeds video up preserves
/// pitch — it stretches time and leaves the voice where it was. Undoing that by
/// resampling would halve the pitch as well as the rate and hand the recognizer
/// a baritone it likes even less. `AVAudioUnitTimePitch` stretches time on its
/// own, which is the inverse of what the player did.
///
/// The engine runs in manual rendering mode and stays alive for the session:
/// one per chunk would put a seam every second, exactly where words are.
public final class SpeedCorrector: @unchecked Sendable {
    public enum SpeedError: Error, Sendable {
        case formatUnavailable
        case engineFailed(String)
    }

    /// Playback speeds worth offering. Beyond 2× the recognizer has nothing
    /// left to work with even after stretching.
    public static let supportedRates: [Double] = [1, 1.25, 1.5, 1.75, 2]

    private let rate: Double
    private let format: AVAudioFormat
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let stretch = AVAudioUnitTimePitch()
    private let lock = NSLock()

    /// Nil when the rate is 1 — there is nothing to undo, and running audio
    /// through a stretcher that is not stretching only adds latency and risk.
    public static func make(rate: Double, sampleRate: Double = 16_000) -> SpeedCorrector? {
        guard rate > 1.01 else { return nil }
        return try? SpeedCorrector(rate: rate, sampleRate: sampleRate)
    }

    init(rate: Double, sampleRate: Double = 16_000) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw SpeedError.formatUnavailable }

        self.rate = rate
        self.format = format
        // 0.5 plays back at half speed, which is what undoes a 2x recording.
        stretch.rate = Float(1 / rate)

        engine.attach(player)
        engine.attach(stretch)
        engine.connect(player, to: stretch, format: format)
        engine.connect(stretch, to: engine.mainMixerNode, format: format)

        do {
            try engine.enableManualRenderingMode(
                .offline, format: format, maximumFrameCount: 8_192)
            try engine.start()
        } catch {
            throw SpeedError.engineFailed("\(error)")
        }
        player.play()
    }

    deinit {
        player.stop()
        engine.stop()
    }

    /// Stretches one chunk. Output is `rate` times longer than the input.
    public func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }

        guard let input = AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return samples }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress,
                  let destination = input.floatChannelData?[0] else { return }
            destination.update(from: base, count: samples.count)
        }
        player.scheduleBuffer(input, completionHandler: nil)

        // Deterministic: a chunk slowed to 1/rate speed is rate times longer.
        let wanted = Int((Double(samples.count) * rate).rounded())
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount)
        else { return samples }

        var out: [Float] = []
        out.reserveCapacity(wanted)
        while out.count < wanted {
            let remaining = AVAudioFrameCount(min(
                Int(engine.manualRenderingMaximumFrameCount), wanted - out.count))
            guard let status = try? engine.renderOffline(remaining, to: scratch),
                  status == .success, scratch.frameLength > 0,
                  let rendered = scratch.floatChannelData?[0]
            else { break }
            out.append(contentsOf: UnsafeBufferPointer(
                start: rendered, count: Int(scratch.frameLength)))
        }
        return out
    }
}
