import Foundation
import AppKit
import FlowLocalCore

/// M2 acceptance harness: real hotkeys, real microphone, no ASR yet.
///
/// Proves the two things M2 must get right — that each gesture on each key
/// produces audio of the correct length, and that the audio contains actual
/// signal rather than silence.
final class Listener: @unchecked Sendable {
    private var capture: AudioCapture?
    private var hotkeys: HotkeyManager?
    private var cursors: [CleanupMode: UInt64] = [:]
    private let lock = NSLock()

    /// Retained by the callbacks it installs, so it outlives `run()`.
    static func run() {
        let listener = Listener()
        listener.start()
    }

    private func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        log("\n=== FlowLocal listener — \(Date()) ===")

        let permissions = Permissions()
        let status = permissions.status()
        guard status.accessibility else {
            log("FAIL: Accessibility not granted — the event tap cannot start.")
            return
        }
        guard status.microphone == .authorized else {
            log("FAIL: microphone not authorized (\(status.microphone))")
            return
        }

        do {
            let capture = try AudioCapture()
            capture.onInterruption = { reason in log("!! capture interrupted: \(reason)") }
            try capture.start()
            self.capture = capture
            log("audio capture running — 16 kHz mono, 30 s preroll")
        } catch {
            log("FAIL: audio capture — \(error)")
            return
        }

        let hotkeys = HotkeyManager(lightTouch: .rightOption, fullRewrite: .rightCommand)
        hotkeys.onSignal = { [self] signal in handle(signal) }
        do {
            try hotkeys.start()
            self.hotkeys = hotkeys
        } catch {
            log("FAIL: hotkey tap — \(error)")
            return
        }

        log("""

        READY. Try each of these:
          • HOLD Right Option, speak, release        -> light-touch, hold
          • DOUBLE-TAP Right Option, speak, tap once -> light-touch, toggle
          • HOLD Right Command, speak, release       -> full rewrite, hold
        Quit with Ctrl-C or `killall FlowLocal`.
        """)

        app.run()
    }

    private func handle(_ signal: HotkeyManager.Signal) {
        switch signal {
        case .tapDisabled(let reason):
            log("!! \(reason) — recording aborted")

        case .gesture(let mode, let action):
            guard let capture else { return }
            switch action {
            case .beginRecording(let kind):
                lock.lock(); defer { lock.unlock() }
                // Rewind slightly: the press is recognized after speech may have
                // begun, which is exactly what the preroll buffer exists for.
                let preroll = 0.4
                let back = UInt64(preroll * capture.buffer.sampleRate)
                let now = capture.buffer.writeCursor
                cursors[mode] = now > back ? now - back : 0
                log("[\(label(mode))] begin (\(kind))")

            case .discardAndRestart:
                lock.lock(); defer { lock.unlock() }
                cursors[mode] = capture.buffer.writeCursor
                log("[\(label(mode))] double-tap detected — discarded, now hands-free")

            case .finishRecording(let kind):
                lock.lock()
                let started = cursors.removeValue(forKey: mode)
                lock.unlock()
                guard let start = started else { return }
                let overran = capture.buffer.hasOverrun(cursor: start)
                let (samples, _) = capture.buffer.read(from: start)
                let seconds = Double(samples.count) / capture.buffer.sampleRate
                let rms = rootMeanSquare(samples)
                let peak = samples.map(abs).max() ?? 0
                log(String(
                    format: "[%@] finish (%@)  %.2f s  %d samples  rms %.4f  peak %.3f  %@%@",
                    label(mode), "\(kind)", seconds, samples.count, rms, peak,
                    rms > 0.001 ? "SIGNAL" : "SILENCE — check input device",
                    overran ? "  !! ring buffer overran" : ""))

            case .none:
                break
            }
        }
    }

    private func label(_ mode: CleanupMode) -> String {
        mode == .lightTouch ? "light" : "rewrite"
    }

    private func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}
