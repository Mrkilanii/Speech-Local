import Foundation
import AppKit
import AVFoundation
import CoreAudio
import CoreGraphics
import ScreenCaptureKit

/// Measures whether system audio — the other people on a call — can be
/// captured, and at what cost in permissions.
///
/// Run before anything depends on it:
///
///     open dist/SpeechLocal.app --args --probe-audio-sources
///
/// **From the bundle, not the terminal.** A permission grant attaches to the
/// responsible process, so a shell run grants it to Terminal and the answer
/// this prints is about Terminal rather than about SpeechLocal.
///
/// Two candidates, because the choice cannot be settled by argument:
///
/// * **CoreAudio process tap** (`AudioHardwareCreateProcessTap`, macOS 14.2+) —
///   audio asking for audio permission. A global mono tap excluding our own
///   process, wired into a private aggregate device.
/// * **ScreenCaptureKit** (`SCStream`, macOS 13+) — a screen-capture session
///   whose video is discarded. Better documented, but it asks for Screen
///   Recording and lights the purple indicator, which is a strange thing for a
///   note-taker to do.
enum AudioSourceProbe {
    static let seconds = 6.0

    static func run() async {
        // A TCC dialog needs a WindowServer connection and a running run loop —
        // the same reason PermissionSetup initializes NSApplication first.
        // Without this, AudioDeviceStart blocks forever on a decision that can
        // never be presented.
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
        }

        log("=== system audio probe ===")
        log("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        log("bundle: \(Bundle.main.bundleIdentifier ?? "NONE — not bundled")")
        // Which of these is already true decides whether a fresh install
        // prompts. Beware: launched from a terminal, the grant being reported
        // may be the terminal's, not ours.
        log("screen recording already granted: \(CGPreflightScreenCaptureAccess())")
        log("microphone: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue) (3 = authorized)")
        log("")

        // Off the main thread as well: the HAL calls below are synchronous and
        // block until TCC answers, and the main thread has to stay free to
        // render the dialog that answers it.
        let tap = await Task.detached(priority: .userInitiated) {
            await probeProcessTap()
        }.value
        log("[tap] \(tap.summary)")

        log("")
        let screen = await probeScreenCaptureKit()
        log("[sck] \(screen.summary)")

        log("")
        log("=== verdict ===")
        log("  CoreAudio process tap : \(tap.summary)")
        log("  ScreenCaptureKit      : \(screen.summary)")
        log("")
        log("Silence on both with audio playing means neither path is usable")
        log("as configured — check System Settings > Privacy for what was asked.")
    }

    struct Result {
        var frames = 0
        var peak: Float = 0
        var rms: Float = 0
        var error: String?

        var summary: String {
            if let error { return "FAILED — \(error)" }
            guard frames > 0 else { return "no audio delivered" }
            let level = String(format: "rms %.4f peak %.4f", rms, peak)
            return frames > 0 && rms > 0.0001
                ? "WORKS — \(frames) frames, \(level)"
                : "silent — \(frames) frames, \(level)"
        }
    }

    // MARK: - CoreAudio process tap

    private static func probeProcessTap() async -> Result {
        log("[tap] creating a global mono tap, excluding ourselves…")

        guard let ourProcess = processObject(for: getpid()) else {
            return Result(error: "could not translate our pid to an audio process object")
        }

        let description = CATapDescription()
        description.name = "SpeechLocal probe"
        description.processes = [ourProcess]
        description.isMono = true
        description.isExclusive = true          // exclude the listed process
        description.isMixdown = true
        description.isPrivate = true
        description.muteBehavior = .unmuted     // never silence the user's speakers

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let created = AudioHardwareCreateProcessTap(description, &tapID)
        guard created == noErr, tapID != kAudioObjectUnknown else {
            return Result(error: "AudioHardwareCreateProcessTap -> \(status(created))")
        }
        defer { AudioHardwareDestroyProcessTap(tapID) }
        log("[tap] tap \(tapID) created")

        guard let uid = tapUID(tapID) else {
            return Result(error: "tap has no UID")
        }

        var aggregate = AudioObjectID(kAudioObjectUnknown)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SpeechLocal probe",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: uid,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        let madeDevice = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &aggregate)
        guard madeDevice == noErr, aggregate != kAudioObjectUnknown else {
            return Result(error: "AudioHardwareCreateAggregateDevice -> \(status(madeDevice))")
        }
        defer { AudioHardwareDestroyAggregateDevice(aggregate) }
        log("[tap] aggregate device \(aggregate) created, reading for \(Int(seconds))s…")

        // The IOProc runs on a real-time thread: no allocation, no locking.
        let meter = Meter()
        var procID: AudioDeviceIOProcID?
        let installed = AudioDeviceCreateIOProcIDWithBlock(
            &procID, aggregate, nil
        ) { _, input, _, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: input))
            for buffer in buffers {
                guard let data = buffer.mData else { continue }
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                meter.add(data.assumingMemoryBound(to: Float.self), count: count)
            }
        }
        guard installed == noErr, let procID else {
            return Result(error: "AudioDeviceCreateIOProcIDWithBlock -> \(status(installed))")
        }
        defer { AudioDeviceDestroyIOProcID(aggregate, procID) }

        let started = AudioDeviceStart(aggregate, procID)
        guard started == noErr else {
            return Result(error: "AudioDeviceStart -> \(status(started))")
        }
        try? await Task.sleep(for: .seconds(seconds))
        AudioDeviceStop(aggregate, procID)

        return meter.result()
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return result == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func tapUID(_ tapID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let result = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        return result == noErr ? uid as String : nil
    }

    // MARK: - ScreenCaptureKit

    private static func probeScreenCaptureKit() async -> Result {
        log("[sck] asking for shareable content…")
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
        } catch {
            return Result(error: "SCShareableContent -> \(error.localizedDescription)")
        }
        guard let display = content.displays.first else {
            return Result(error: "no displays reported")
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // Video cannot be switched off, so make it as cheap as possible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let sink = AudioSink()
        do {
            try stream.addStreamOutput(sink, type: .audio,
                                       sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()
        } catch {
            return Result(error: "startCapture -> \(error.localizedDescription)")
        }
        log("[sck] capturing for \(Int(seconds))s…")
        try? await Task.sleep(for: .seconds(seconds))
        try? await stream.stopCapture()

        return sink.meter.result()
    }

    private final class AudioSink: NSObject, SCStreamOutput {
        let meter = Meter()

        func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .audio, buffer.isValid else { return }
            // The buffer list is only valid inside the closure — carrying it
            // out and reading it afterwards is a use-after-free, and segfaults
            // on the first callback.
            _ = try? buffer.withAudioBufferList(blockBufferMemoryAllocator: nil) { list, _ in
                for audio in list {
                    guard let data = audio.mData else { continue }
                    let count = Int(audio.mDataByteSize) / MemoryLayout<Float>.size
                    meter.add(data.assumingMemoryBound(to: Float.self), count: count)
                }
            }
        }
    }

    // MARK: - Measurement

    /// Accumulates level across real-time callbacks. `@unchecked Sendable`
    /// because the audio thread is the only writer and the reader runs after
    /// it has stopped.
    final class Meter: @unchecked Sendable {
        private var frames = 0
        private var peak: Float = 0
        private var sumOfSquares: Double = 0

        func add(_ samples: UnsafePointer<Float>, count: Int) {
            for index in 0..<count {
                let sample = abs(samples[index])
                if sample > peak { peak = sample }
                sumOfSquares += Double(sample) * Double(sample)
            }
            frames += count
        }

        func result() -> Result {
            guard frames > 0 else { return Result() }
            return Result(frames: frames, peak: peak,
                          rms: Float((sumOfSquares / Double(frames)).squareRoot()))
        }
    }

    private static func status(_ code: OSStatus) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let text = String(chars)
        return text.allSatisfy(\.isLetter) ? "'\(text)' (\(code))" : "\(code)"
    }
}
