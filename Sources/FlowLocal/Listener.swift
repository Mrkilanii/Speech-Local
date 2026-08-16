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
    private var status: StatusItem?
    private var panel: DictationPanel?
    private let asr = AppleASREngine()
    /// Rebuilt per dictation so a settings change takes effect immediately.
    private var cleanup: RoutingCleanupEngine {
        RoutingCleanupEngine(
            llm: AppleCleanupEngine(),
            rules: RulesCleanup(commaPolicy:
                settingsStore.current.commaPolicy == .sparse ? .sparse : .tidy)
        )
    }
    private var vocabulary: Vocabulary { settingsStore.current.vocabulary }
    private let learned = LearnedCorrections()
    private let settingsStore = SettingsStore()
    private var settingsWindow: SettingsWindow?
    private let inserter = TextInserter()
    /// Last raw ASR output, kept so a correction can be diffed against it.
    private var lastRaw: String?
    /// Audio from a cancelled dictation, retained so Undo can still transcribe it.
    private var cancelledSamples: [Float]?
    private var cancelledMode: CleanupMode?

    /// Retained by the callbacks it installs, so it outlives `run()`.
    @MainActor
    static func run() {
        let listener = Listener()
        listener.start()
    }

    @MainActor
    private func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        status = StatusItem()
        status?.onCorrect = { [weak self] in self?.correctLast() }
        status?.onSettings = { [weak self] in self?.openSettings() }

        let panel = DictationPanel()
        // Live level comes from the tail of the ring buffer, so the waveform
        // reflects what the microphone is actually hearing right now.
        panel.levelProvider = { [weak self] in
            guard let buffer = self?.capture?.buffer else { return 0 }
            let recent = buffer.snapshot(lastSeconds: 0.08)
            guard !recent.isEmpty else { return 0 }
            let sum = recent.reduce(0.0) { $0 + Double($1) * Double($1) }
            return (sum / Double(recent.count)).squareRoot()
        }
        panel.onCancel = { [weak self] in self?.cancelActive() }
        panel.onConfirm = { [weak self] in self?.confirmActive() }
        panel.onUndo = { [weak self] in self?.undoCancel() }
        panel.onDismiss = { }
        self.panel = panel
        panel.show(.hidden)   // resting pill, always visible

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

        let configured = settingsStore.current
        let hotkeys = HotkeyManager(
            lightTouch: Self.key(for: configured.lightTouchKey),
            fullRewrite: Self.key(for: configured.fullRewriteKey))
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
            Task { @MainActor in self.status?.apply(.error(reason)) }

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
                Task { @MainActor in
                    self.status?.apply(.recording(mode))
                    if self.settingsStore.current.playSounds { self.status?.chime(start: true) }
                    self.panel?.show(.listening(mode: mode))
                }

            case .discardAndRestart:
                lock.lock(); defer { lock.unlock() }
                cursors[mode] = capture.buffer.writeCursor
                log("[\(label(mode))] double-tap detected — discarded, now hands-free")
                Task { @MainActor in self.status?.report("Hands-free — tap to stop") }

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
                let summary = String(
                    format: "%@ %@ — %.1f s, %@", label(mode), "\(kind)", seconds,
                    rms > 0.001 ? "audio OK" : "SILENT")
                Task { @MainActor in
                    self.status?.apply(.processing)
                    if self.settingsStore.current.playSounds { self.status?.chime(start: false) }
                    self.status?.report(summary)
                    self.panel?.show(.processing)
                }
                Task { await self.transcribe(samples: samples, mode: mode) }

            case .none:
                break
            }
        }
    }

    /// M3: audio -> transcript -> cleaned text. Insertion arrives in M4, so the
    /// result is logged and shown in the menu rather than typed anywhere yet.
    private func transcribe(samples: [Float], mode: CleanupMode) async {
        guard let rate = capture?.buffer.sampleRate else { return }
        let t0 = Date()
        do {
            let bias = await learned.biasTerms()
            let heard = try await asr.transcribe(
                samples: samples, sampleRate: rate, locale: settingsStore.current.locale, biasTerms: bias)
            // Repair only fires where a learned correction's context recurs.
            let raw = await learned.repair(heard)
            if raw != heard { log("  LEARNED  \"\(heard)\" -> \"\(raw)\"") }
            let asrMs = Date().timeIntervalSince(t0) * 1000

            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                log("  ASR returned nothing (silence, or speech too quiet)")
                await MainActor.run {
                    self.status?.apply(.idle)
                    self.status?.report("No speech detected")
                    self.panel?.show(.failed("No speech detected"))
                }
                return
            }
            log(String(format: "  ASR   %5.0f ms  \"%@\"%@", asrMs, raw,
                       bias.isEmpty ? "" : "  (biased toward \(bias.count) learned term(s))"))
            lastRaw = raw
            await MainActor.run { self.status?.allowCorrection(true) }

            let t1 = Date()
            var cleaned = raw
            do {
                for try await partial in cleanup.stream(
                    transcript: raw, mode: mode, vocabulary: vocabulary
                ) { cleaned = partial }
            } catch {
                // Degrade loudly, never lose text.
                log("  CLEANUP FAILED (\(error)) — falling back to raw transcript")
                cleaned = raw
            }
            let cleanMs = Date().timeIntervalSince(t1) * 1000
            let totalMs = Date().timeIntervalSince(t0) * 1000

            log(String(format: "  CLEAN %5.0f ms  \"%@\"", cleanMs, cleaned))
            log(String(format: "  TOTAL %5.0f ms", totalMs))

            // M4: put the text where the user is actually typing.
            log("  FOCUS \(await inserter.describeFocus())")
            do {
                let method = try await inserter.insert(cleaned)
                log("  INSERT via \(method.rawValue)")
                await MainActor.run {
                    self.status?.apply(.idle)
                    self.status?.report(String(cleaned.prefix(60)))
                    self.panel?.flashInserted()
                }
            } catch {
                // Nowhere to type it: show the text in the pill with a copy
                // button rather than discarding it.
                if case TextInserter.InsertError.noTextInput = error {
                    log("  no text field focused — offering the text to copy")
                } else {
                    log("  INSERT FAILED (\(error)) — offering the text to copy")
                }
                await MainActor.run {
                    self.status?.apply(.idle)
                    self.status?.report(String(cleaned.prefix(60)))
                    self.panel?.show(.result(cleaned))
                }
            }
        } catch {
            log("  ASR FAILED: \(error)")
            await MainActor.run {
                self.status?.apply(.error("transcription failed"))
                self.status?.report("ASR failed: \(error)")
                self.panel?.show(.failed("Transcription failed"))
            }
        }
    }

    private static func key(for choice: HotkeyChoice) -> HotkeyManager.Key {
        switch choice {
        case .rightOption:  return .rightOption
        case .rightCommand: return .rightCommand
        case .rightControl: return .rightControl
        case .fn:           return .fn
        }
    }

    @MainActor
    private func openSettings() {
        if settingsWindow == nil {
            let window = SettingsWindow(store: settingsStore, corrections: learned)
            // Rebinding requires tearing the event tap down and back up; the old
            // one is still watching the previous keycodes.
            window.onHotkeysChanged = { [weak self] (settings: FlowLocalCore.Settings) in
                guard let self else { return }
                self.hotkeys?.stop()
                let rebuilt = HotkeyManager(
                    lightTouch: Self.key(for: settings.lightTouchKey),
                    fullRewrite: Self.key(for: settings.fullRewriteKey))
                rebuilt.onSignal = { [weak self] signal in self?.handle(signal) }
                try? rebuilt.start()
                self.hotkeys = rebuilt
                log("hotkeys rebound: \(settings.lightTouchKey.displayName) / "
                    + "\(settings.fullRewriteKey.displayName)")
            }
            settingsWindow = window
        }
        settingsWindow?.show()
    }

    /// X button: stop and discard. The audio is kept so Undo can recover it.
    @MainActor
    private func cancelActive() {
        guard let hotkeys, let capture else { return }
        hotkeys.activeMode { [weak self] mode in
            guard let self, let mode else { return }
            hotkeys.endGesture(mode, process: false)
            self.lock.lock()
            let started = self.cursors.removeValue(forKey: mode)
            self.lock.unlock()
            if let started {
                let (samples, _) = capture.buffer.read(from: started)
                self.cancelledSamples = samples
                self.cancelledMode = mode
            }
            log("[\(self.label(mode))] cancelled by user")
            Task { @MainActor in self.panel?.show(.cancelled) }
        }
    }

    /// Checkmark: stop listening now and process what was captured.
    @MainActor
    private func confirmActive() {
        guard let hotkeys else { return }
        hotkeys.activeMode { mode in
            guard let mode else { return }
            hotkeys.endGesture(mode, process: true)
        }
    }

    /// Undo: transcribe the audio that was just discarded after all.
    @MainActor
    private func undoCancel() {
        guard let samples = cancelledSamples, let mode = cancelledMode else { return }
        cancelledSamples = nil
        cancelledMode = nil
        log("  undo — transcribing the cancelled audio after all")
        panel?.show(.processing)
        Task { await self.transcribe(samples: samples, mode: mode) }
    }

    /// Opens the correction prompt and learns from whatever the user changes.
    @MainActor
    private func correctLast() {
        guard let raw = lastRaw, let status else { return }
        guard let corrected = status.askForCorrection(original: raw) else { return }
        Task {
            let learnedNow = await self.learned.learnFromEdit(raw: raw, corrected: corrected)
            if learnedNow.isEmpty {
                log("  correction ignored — only same-length word swaps are learned")
                await MainActor.run {
                    status.report("Not learned (word count changed)")
                }
                return
            }
            for correction in learnedNow {
                log("  LEARN  \"\(correction.heard)\" -> \"\(correction.intended)\" "
                    + "(seen \(correction.timesSeen)x, context: \(correction.before ?? "-")/\(correction.after ?? "-"))")
            }
            let total = await self.learned.count()
            await MainActor.run {
                status.report("Learned \(learnedNow.count) — \(total) total")
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
