import Foundation
import AVFoundation

/// Continuous microphone capture into an `AudioRingBuffer`.
///
/// Runs from app launch, not from hotkey press. That is deliberate: the first
/// key-down cannot be classified as hold-vs-double-tap until the gesture
/// resolves, so audio must already exist for the moment *before* the press was
/// recognized. Starting capture on press would clip every utterance's opening
/// syllable.
///
/// The tap callback runs on Core Audio's real-time thread. It must not
/// allocate, lock, or log — everything it needs is preallocated in `init`.
public final class AudioCapture: @unchecked Sendable {
    public enum CaptureError: Error, Sendable {
        case engineFailed(String)
        case converterUnavailable
        case permissionDenied
    }

    public let buffer: AudioRingBuffer

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var scratch: AVAudioPCMBuffer?
    private let lock = NSLock()
    private var running = false

    /// Called when capture stops unexpectedly — route change, device removal,
    /// or engine failure. The pipeline must treat this as an abort, not a pause:
    /// a dictation in flight has lost its audio.
    public var onInterruption: (@Sendable (String) -> Void)?

    public init(sampleRate: Double = 16_000, historySeconds: Double = 30) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw CaptureError.converterUnavailable }

        self.targetFormat = format
        self.buffer = AudioRingBuffer(seconds: historySeconds, sampleRate: sampleRate)

        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Route changed (Bluetooth mic yanked, headphones plugged in). The
            // engine's input format may now differ, so restart rather than keep
            // feeding a stale converter.
            self?.handleConfigurationChange()
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !running else { return }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw CaptureError.permissionDenied
        }

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            throw CaptureError.engineFailed("input format has zero sample rate")
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        // Preallocated generously so the real-time callback never allocates.
        let capacity = AVAudioFrameCount(targetFormat.sampleRate)  // 1 s
        guard let scratch = AVAudioPCMBuffer(
            pcmFormat: targetFormat, frameCapacity: capacity
        ) else { throw CaptureError.converterUnavailable }
        self.scratch = scratch

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) {
            [weak self] pcm, _ in
            self?.ingest(pcm)
        }

        engine.prepare()
        do { try engine.start() }
        catch { throw CaptureError.engineFailed("\(error)") }
        running = true
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    // MARK: - Real-time path

    /// Converts to 16 kHz mono and appends to the ring buffer.
    ///
    /// Runs on the audio thread. No allocation, no locking, no logging.
    private func ingest(_ pcm: AVAudioPCMBuffer) {
        guard let converter, let scratch else { return }

        scratch.frameLength = 0
        var supplied = false
        var conversionError: NSError?

        let status = converter.convert(to: scratch, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return pcm
        }

        guard status == .haveData || status == .inputRanDry,
              let channel = scratch.floatChannelData?[0],
              scratch.frameLength > 0
        else { return }

        buffer.write(UnsafeBufferPointer(start: channel, count: Int(scratch.frameLength)))
    }

    private func handleConfigurationChange() {
        let wasRunning = isRunning
        stop()
        onInterruption?("audio route changed")
        guard wasRunning else { return }
        // Best effort restart; if the new device is unusable the next dictation
        // reports it rather than silently recording nothing.
        try? start()
    }
}
