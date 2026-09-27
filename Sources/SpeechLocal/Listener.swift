import Foundation
import AppKit
import SpeechLocalCore

/// M2 acceptance harness: real hotkeys, real microphone, no ASR yet.
///
/// Proves the two things M2 must get right — that each gesture on each key
/// produces audio of the correct length, and that the audio contains actual
/// signal rather than silence.
final class Listener: @unchecked Sendable {
    private var capture: AudioCapture?
    private var hotkeys: HotkeyManager?
    private var cursors: [CleanupMode: UInt64] = [:]
    /// Audio drained out of the ring while recording. The ring is a 30 s preroll
    /// window, not storage: a hands-free session can run for minutes, and
    /// leaving the audio there means the producer laps the consumer and silently
    /// eats the beginning. Observed at 32.77 s against a 32.768 s ring.
    private var sessionSamples: [CleanupMode: [Float]] = [:]
    /// The recognizer for each dictation in progress, fed by the same drain as
    /// `sessionSamples`. Transcribing only after release made the wait grow
    /// with the length of the dictation — a median 275 ms under 5 s, 2.7 s
    /// past a minute, over 2,852 logged dictations. Listening while the key is
    /// held leaves only finalisation for the release.
    private var streams: [CleanupMode: LiveStream] = [:]
    private var drainTimer: Timer?
    private let lock = NSLock()
    private var status: StatusItem?
    private var panel: DictationPanel?
    private let asr = AppleASREngine()
    /// Rebuilt per dictation so a settings change takes effect immediately.
    private var cleanup: RoutingCleanupEngine {
        RoutingCleanupEngine(
            llm: AppleCleanupEngine(),
            rules: RulesCleanup(
                commaPolicy: settingsStore.current.commaPolicy == .sparse ? .sparse : .tidy,
                language: Language(localeIdentifier: settingsStore.current.locale))
        )
    }
    private var vocabulary: Vocabulary { settingsStore.current.vocabulary }
    private let learned = LearnedCorrections()
    private let settingsStore = SettingsStore()
    private var settingsWindow: SettingsWindow?
    private var notesWindow: NotesWindow?
    private var notesModel: NotesModel?
    private let inserter = TextInserter()
    private let lifecycle = LifecycleMonitor()
    private let history = TranscriptHistory()
    /// Last raw ASR output, kept so a correction can be diffed against it.
    private var lastRaw: String?
    /// Audio from a cancelled dictation, retained so Undo can still transcribe it.
    private var cancelledSamples: [Float]?
    private var cancelledMode: CleanupMode?
    /// What was last typed, for "Paste last transcript".
    private var lastInserted: String?

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
        status?.onNotes = { [weak self] in self?.openNotes() }
        status?.onMeeting = { [weak self] in
            guard let self else { return }
            self.openNotes()
            self.notesWindow?.toggleRecording()
        }
        status?.onSettings = { [weak self] in self?.openSettings() }
        status?.onRestoreClipboard = { [weak self] in
            guard let self else { return }
            Task {
                let restored = await self.inserter.restorePreviousClipboard()
                log(restored ? "  PASTE restored by hand" : "  PASTE nothing held to restore")
                await MainActor.run {
                    self.status?.report(restored ? "Clipboard restored" : "Nothing to restore")
                }
            }
        }
        status?.onPasteLast = { [weak self] in
            guard let self, let text = self.lastInserted else { return }
            // The menu takes focus; give it back to the app first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                Task { _ = try? await self.inserter.insert(text) }
            }
        }
        Task { [inserter] in
            await inserter.setPasteEventHandler { line in log("  " + line) }
        }

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

        // Sleep, lock, or user switch abandons the dictation. Audio capture
        // stops but the gesture does not, so without this a key held across a
        // lid close would transcribe pre-sleep audio on wake and insert it
        // wherever the cursor had moved to.
        lifecycle.onInterrupt = { [weak self] reason in
            Task { @MainActor in self?.abandonActive(reason: reason) }
        }
        lifecycle.onAccessibilityLost = { [weak self] in
            log("!! Accessibility revoked — hotkeys are dead until it is restored")
            Task { @MainActor in
                self?.status?.apply(.error("Accessibility off — hotkeys disabled"))
                self?.status?.report("Grant Accessibility in System Settings")
                self?.panel?.show(.failed("Accessibility turned off — hotkeys disabled"))
            }
        }
        lifecycle.onAccessibilityRestored = { [weak self] in
            log("Accessibility restored — rebuilding the event tap")
            Task { @MainActor in
                guard let self else { return }
                // The old tap died with the permission; re-enabling it does
                // nothing, so it must be rebuilt from scratch.
                self.hotkeys?.stop()
                let settings = self.settingsStore.current
                let rebuilt = HotkeyManager(
                    lightTouch: Self.key(for: settings.lightTouchKey),
                    fullRewrite: Self.key(for: settings.fullRewriteKey),
                    code: Self.key(for: settings.codeKey))
                rebuilt.onSignal = { [weak self] signal in self?.handle(signal) }
                try? rebuilt.start()
                self.hotkeys = rebuilt
                self.status?.apply(.idle)
                self.status?.report("Accessibility restored")
            }
        }
        lifecycle.start()
        self.panel = panel
        panel.show(.hidden)   // resting pill, always visible

        log("\n=== SpeechLocal listener — \(Date()) ===")

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
            fullRewrite: Self.key(for: configured.fullRewriteKey),
            code: Self.key(for: configured.codeKey))
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
        Quit with Ctrl-C or `killall SpeechLocal`.
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
                // Recording starts at the press, not before it. This used to
                // rewind 0.4 s — a number nothing ever measured — and it caught
                // the tail of whatever was said just before pressing, which then
                // turned up in the transcript. The press is seen on key-down
                // within milliseconds, so there is no detection lag to cover.
                // If opening syllables start getting clipped, the answer is a
                // small measured rewind, not the old guess.
                cursors[mode] = capture.buffer.writeCursor
                sessionSamples[mode] = []
                streams.removeValue(forKey: mode)?.feed.finish()   // never expected; never leaked
                streams[mode] = openStream(bias: prepareBias())
                Task { @MainActor in self.startDraining() }
                log("[\(label(mode))] begin (\(kind))")
                Task { @MainActor in
                    self.status?.apply(.recording(mode))
                    if self.settingsStore.current.playSounds { self.status?.chime(start: true) }
                    self.panel?.show(.listening(mode: mode))
                }

            case .discardAndRestart:
                lock.lock(); defer { lock.unlock() }
                cursors[mode] = capture.buffer.writeCursor
                sessionSamples[mode] = []
                // The recognizer has heard the first tap, so it is replaced, not
                // reused. The bias is kept: it was computed for this same press,
                // and computing it again would harvest the last edit twice.
                let old = streams.removeValue(forKey: mode)
                old?.feed.finish()
                streams[mode] = openStream(bias: old?.bias ?? prepareBias())
                log("[\(label(mode))] double-tap detected — discarded, now hands-free")
                Task { @MainActor in self.status?.report("Hands-free — tap to stop") }

            case .finishRecording(let kind):
                // Keep listening a moment past the release. Letting go of the
                // key a beat early cut the last syllable, and a one-word
                // dictation cut that way came back empty (2 of 15 in the
                // trimmed-clip test, 27 Sep). 150 ms is not noticeable.
                let released = Date()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { [self] in
                    self.finish(mode: mode, kind: kind, capture: capture, released: released)
                }

            case .none:
                break
            }
        }
    }

    private func finish(mode: CleanupMode, kind: HotkeyGesture.Mode, capture: AudioCapture,
                        released: Date) {
        // Refused before any recognition: nothing said at a password
        // prompt should reach the recognizer, the log or history.
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if case .refuse(let reason) = InsertionGuard.check(
            bundleID: front, secureInputEnabled: false, focusedSubrole: nil) {
            lock.lock()
            cursors.removeValue(forKey: mode)
            sessionSamples.removeValue(forKey: mode)
            streams.removeValue(forKey: mode)?.feed.finish()   // text never read
            lock.unlock()
            Task { @MainActor in self.stopDrainingIfIdle() }
            log("[\(label(mode))] REFUSED \(reason) — audio discarded, not transcribed")
            Task { @MainActor in
                self.status?.apply(.idle)
                self.panel?.show(.failed("Not dictating into a password prompt"))
            }
            return
        }
        // Drain FIRST. drain() iterates `cursors`, so removing the entry
        // before draining silently discarded everything captured since
        // the last tick — up to a second of speech, always from the end.
        lock.lock()
        let started = cursors[mode]
        lock.unlock()
        guard let start = started else { return }
        let overran = capture.buffer.hasOverrun(cursor: start)
        drain()

        lock.lock()
        cursors.removeValue(forKey: mode)
        let samples = sessionSamples.removeValue(forKey: mode) ?? []
        let live = streams.removeValue(forKey: mode)
        lock.unlock()
        if let live {
            live.feed.yield(silence())   // the trailing half of the padding
            live.feed.finish()           // end of input: the recognizer finalises
        }
        Task { @MainActor in self.stopDrainingIfIdle() }
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
        Task {
            if let live {
                await self.finishLive(live, samples: samples, mode: mode, released: released)
            } else {
                await self.transcribe(samples: samples, mode: mode)
            }
        }
    }

    /// The recognizer for one dictation, listening while the key is held.
    private struct LiveStream {
        let feed: AsyncStream<AudioChunk>.Continuation
        /// Learned terms, computed once at the press. The recognizer is built
        /// with them, so they cannot wait until release.
        let bias: Task<[String], Never>
        /// The finalised transcript, once the feed is finished.
        let text: Task<String, Error>
    }

    /// Harvests the last edit and reads the learned terms, off the hotkey
    /// queue. Before biasing, so a fix made since the last dictation counts
    /// towards this one.
    private func prepareBias() -> Task<[String], Never> {
        let learnFromEdits = settingsStore.current.learnFromEdits
        return Task {
            if learnFromEdits { await self.harvestEdit() }
            return await self.learned.biasTerms()
        }
    }

    /// Starts a recognizer on an empty feed, opened with half a second of
    /// silence (see `silence()`). Audio buffers in the stream until the bias is
    /// ready, so nothing said in the meantime is lost.
    ///
    /// A discarded stream is closed with `feed.finish()` and left to wind down,
    /// never cancelled: cancelling makes the engine throw out of its feed loop
    /// without finishing the analyzer's input, and what that does afterwards
    /// has not been measured.
    private func openStream(bias: Task<[String], Never>) -> LiveStream {
        let (audio, feed) = AsyncStream<AudioChunk>.makeStream()
        feed.yield(silence())
        let locale = settingsStore.current.locale
        let asr = self.asr
        let text = Task { () throws -> String in
            let terms = await bias.value
            var text = ""
            // Each element is the whole transcript so far; the last is final.
            for try await partial in asr.transcribe(audio: audio, locale: locale, biasTerms: terms) {
                text = partial
            }
            return text
        }
        return LiveStream(feed: feed, bias: bias, text: text)
    }

    /// Half a second of silence, fed before and after every dictation. A
    /// one-word line — "else", "try" — came back EMPTY without it (decision
    /// 10), and so do short prose dictations: 7–10% of 1–4 s dictations since
    /// 15 Sep returned nothing, 110 of 184 empties with real signal. On trimmed
    /// clips the padding recovered 15 of 15 against 14 of 15.
    private func silence() -> AudioChunk {
        let rate = capture?.buffer.sampleRate ?? 16_000
        return AudioChunk(samples: [Float](repeating: 0, count: Int(rate * 0.5)), sampleRate: rate)
    }

    /// The whole clip at once, after the fact. Undo uses it, and so does a
    /// dictation whose live recognizer failed or heard nothing.
    private func transcribeBuffered(samples: [Float], bias: [String]) async throws -> String {
        let rate = capture?.buffer.sampleRate ?? 16_000
        let pad = silence().samples
        return try await asr.transcribe(
            samples: pad + samples + pad, sampleRate: rate,
            locale: settingsStore.current.locale, biasTerms: bias)
    }

    /// Release of a live dictation: wait for the recognizer to finalise, then
    /// carry on exactly as the buffered path does.
    private func finishLive(_ live: LiveStream, samples: [Float], mode: CleanupMode,
                            released: Date) async {
        let bias = await live.bias.value
        var heard = ""
        do {
            heard = try await live.text.value
            log(String(format: "  STREAM final +%.0f ms after release",
                       Date().timeIntervalSince(released) * 1000))
        } catch {
            log("  STREAM FAILED (\(error)) — transcribing the recorded audio instead")
        }
        // Empty is retried too: it is what a lost final segment would look
        // like, and on a genuinely silent press the retry is short. Logged, so
        // the log shows whether it ever rescues anything.
        if heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !samples.isEmpty {
            do {
                heard = try await transcribeBuffered(samples: samples, bias: bias)
                log("  STREAM fallback — buffered path heard "
                    + (heard.isEmpty ? "nothing either" : "\"\(heard)\""))
            } catch {
                await reportASRFailure(error)
                return
            }
        }
        await deliver(heard: heard, bias: bias, mode: mode, since: released)
    }

    private func reportASRFailure(_ error: Error) async {
        log("  ASR FAILED: \(error)")
        await MainActor.run {
            self.status?.apply(.error("transcription failed"))
            self.status?.report("ASR failed: \(error)")
            self.panel?.show(.failed("Transcription failed"))
        }
    }

    /// Audio already recorded, transcribed in one go: Undo after a cancel.
    private func transcribe(samples: [Float], mode: CleanupMode) async {
        guard capture != nil else { return }
        let t0 = Date()
        // Before biasing, so a fix made since the last dictation counts
        // towards this one.
        if settingsStore.current.learnFromEdits { await harvestEdit() }
        let bias = await learned.biasTerms()
        do {
            let heard = try await transcribeBuffered(samples: samples, bias: bias)
            await deliver(heard: heard, bias: bias, mode: mode, since: t0)
        } catch {
            await reportASRFailure(error)
        }
    }

    /// Everything after recognition: learned repair, corrections, cleanup,
    /// insertion, history. `t0` is where the logged ASR time starts — the
    /// release, for a live dictation, so the figure is the wait the user has.
    private func deliver(heard: String, bias: [String], mode: CleanupMode, since t0: Date) async {
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

        // Spoken corrections, before cleanup (decision 11). Never in code:
        // "no" and "actually" can be names there.
        var spoken = raw
        if mode != .code, settingsStore.current.backtrack,
           Language(localeIdentifier: settingsStore.current.locale) == .english {
            spoken = Backtrack.apply(raw)
            if spoken != raw { log("  BACKTRACK \"\(spoken)\"") }
            if spoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                log("  everything was scratched — nothing to insert")
                await MainActor.run {
                    self.status?.apply(.idle)
                    self.panel?.show(.failed("Scratched"))
                }
                return
            }
        }

        let t1 = Date()
        var cleaned = spoken
        do {
            for try await partial in cleanup.stream(
                transcript: spoken, mode: mode, vocabulary: vocabulary
            ) { cleaned = partial }
        } catch {
            // Degrade loudly, never lose text.
            log("  CLEANUP FAILED (\(error)) — falling back to raw transcript")
            cleaned = spoken
        }
        let cleanMs = Date().timeIntervalSince(t1) * 1000
        let totalMs = Date().timeIntervalSince(t0) * 1000

        log(String(format: "  CLEAN %5.0f ms  \"%@\"", cleanMs, cleaned))
        log(String(format: "  TOTAL %5.0f ms", totalMs))

        // M4: put the text where the user is actually typing.
        log("  FOCUS \(await inserter.describeFocus())")
        // The caret is often mid-sentence, where cleanup's opening capital
        // is wrong. The target's own text is the only thing that knows.
        let preceding = await inserter.textBeforeCaret()
        // Code has no sentences to open.
        let opened = mode == .code
            ? cleaned : SentenceOpening.adjust(cleaned, following: preceding, raw: spoken)
        if opened != cleaned { log("  OPENING lowercased — caret is mid-sentence") }
        cleaned = opened
        let frontApp = NSWorkspace.shared.frontmostApplication
        if mode != .code {
            cleaned = ChatPunctuation.apply(cleaned, bundleID: frontApp?.bundleIdentifier)
        }
        // History records what was actually typed, after every rule, so
        // "Paste last transcript" and the History tab match the screen.
        // Written only once the guard has had its say.
        let record = { [self] (text: String) async in
            guard self.settingsStore.current.keepHistory else { return }
            await self.history.record(TranscriptEntry(
                raw: heard, cleaned: text, mode: mode, appName: frontApp?.localizedName))
        }
        do {
            let method = mode == .code
                ? try await inserter.insert(
                    PythonDictation.block(PythonDictation.lines(of: raw), caretLine: preceding),
                    multiline: true)
                : try await inserter.insert(cleaned)
            // Editing a line of code afterwards is programming, not
            // correcting a mishearing — nothing there to learn from.
            if mode == .code { await inserter.forgetInsertion() }
            log("  INSERT via \(method.rawValue)")
            lastInserted = cleaned
            await record(cleaned)
            await MainActor.run {
                self.status?.apply(.idle)
                self.status?.report(String(cleaned.prefix(60)))
                self.panel?.flashInserted()
            }
        } catch {
            // Nowhere to type it: show the text in the pill with a copy
            // button rather than discarding it.
            if case TextInserter.InsertError.refused(let reason) = error {
                // Typed at a password prompt or under secure input: not
                // inserted, not kept. Secure input (Terminal's Secure
                // Keyboard Entry) still offers the text to copy.
                log("  REFUSED \(reason) — not inserted, not kept")
                await MainActor.run {
                    self.status?.apply(.idle)
                    if reason == .secureInput {
                        self.panel?.show(.result(cleaned))
                    } else {
                        self.panel?.show(.failed("Not dictating into a password prompt"))
                    }
                }
                return
            }
            await record(cleaned)
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
    }

    private static func key(for choice: HotkeyChoice) -> HotkeyManager.Key {
        switch choice {
        case .rightOption:  return .rightOption
        case .rightCommand: return .rightCommand
        case .rightControl: return .rightControl
        case .fn:           return .fn
        }
    }

    /// The meeting window is built once and kept — it is a place the user
    /// leaves open, not a dialog.
    @MainActor
    private func openNotes() {
        if notesWindow == nil {
            guard let capture else {
                log("  cannot open meeting notes — audio capture is not running")
                return
            }
            let model = NotesModel(
                asr: asr, capture: capture,
                settingsStore: settingsStore, learned: learned)
            // The menu bar follows the real state, from whichever control
            // started it.
            model.onRecordingChanged = { [weak self] running in
                self?.status?.setMeetingRunning(running)
            }
            notesModel = model
            notesWindow = NotesWindow(model: model)
        }
        notesWindow?.show()
    }

    @MainActor
    private func openSettings() {
        if settingsWindow == nil {
            let window = SettingsWindow(
                store: settingsStore, corrections: learned, history: history)
            // Rebinding requires tearing the event tap down and back up; the old
            // one is still watching the previous keycodes.
            window.onHotkeysChanged = { [weak self] (settings: SpeechLocalCore.Settings) in
                guard let self else { return }
                self.hotkeys?.stop()
                let rebuilt = HotkeyManager(
                    lightTouch: Self.key(for: settings.lightTouchKey),
                    fullRewrite: Self.key(for: settings.fullRewriteKey),
                    code: Self.key(for: settings.codeKey))
                rebuilt.onSignal = { [weak self] signal in self?.handle(signal) }
                try? rebuilt.start()
                self.hotkeys = rebuilt
                log("hotkeys rebound: \(settings.lightTouchKey.displayName) / "
                    + "\(settings.fullRewriteKey.displayName) / \(settings.codeKey.displayName)")
            }
            settingsWindow = window
        }
        settingsWindow?.show()
    }

    /// Moves audio out of the ring buffer and into the session accumulator.
    /// Runs often enough that the producer can never lap the consumer.
    @MainActor
    private func startDraining() {
        guard drainTimer == nil || !(drainTimer?.isValid ?? false) else { return }
        drainTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in self.drain() }
        }
    }

    @MainActor
    private func stopDrainingIfIdle() {
        lock.lock()
        let active = !cursors.isEmpty
        lock.unlock()
        guard !active else { return }
        drainTimer?.invalidate()
        drainTimer = nil
    }

    private func drain() {
        guard let capture else { return }
        // Held for the whole pass, reads included. The timer drains on the
        // main thread and a release drains on another queue; two passes
        // reading from the same cursor would hand the recognizer the same
        // second twice, or out of order. The ring read is lock-free, so this
        // never waits on the audio thread.
        lock.lock(); defer { lock.unlock() }
        let pending = cursors

        for (mode, cursor) in pending {
            if capture.buffer.hasOverrun(cursor: cursor) {
                log("[\(label(mode))] WARNING: ring overran between drains — audio lost")
            }
            let (samples, next) = capture.buffer.read(from: cursor)
            guard !samples.isEmpty else { continue }
            sessionSamples[mode, default: []].append(contentsOf: samples)
            cursors[mode] = next
            streams[mode]?.feed.yield(AudioChunk(samples: samples, sampleRate: capture.buffer.sampleRate))
        }
    }

    /// Abandons any dictation in flight and discards its audio.
    @MainActor
    private func abandonActive(reason: String) {
        guard let hotkeys else { return }
        hotkeys.activeMode { [weak self] mode in
            guard let self, let mode else { return }
            hotkeys.endGesture(mode, process: false)
            self.lock.lock()
            self.cursors.removeValue(forKey: mode)
            self.sessionSamples.removeValue(forKey: mode)
            self.streams.removeValue(forKey: mode)?.feed.finish()   // text never read
            self.lock.unlock()
            Task { @MainActor in self.stopDrainingIfIdle() }
            log("[\(self.label(mode))] abandoned — \(reason)")
            Task { @MainActor in
                self.panel?.show(.failed("Dictation stopped — \(reason)"))
            }
        }
    }

    /// X button: stop and discard. The audio is kept so Undo can recover it.
    @MainActor
    private func cancelActive() {
        // Audio is reached through drain() now, so `capture` is not bound here.
        guard let hotkeys else { return }
        hotkeys.activeMode { [weak self] mode in
            guard let self, let mode else { return }
            hotkeys.endGesture(mode, process: false)
            self.drain()                    // must run BEFORE taking the lock
            self.lock.lock()
            let started = self.cursors.removeValue(forKey: mode)
            let accumulated = self.sessionSamples.removeValue(forKey: mode)
            // Undo transcribes the kept samples with the buffered path, so the
            // live recognizer's text is never needed.
            self.streams.removeValue(forKey: mode)?.feed.finish()
            self.lock.unlock()
            Task { @MainActor in self.stopDrainingIfIdle() }
            if started != nil, let accumulated, !accumulated.isEmpty {
                self.cancelledSamples = accumulated
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

    /// Learns from what the user changed in the text last inserted.
    ///
    /// Reading the field back is the whole mechanism, so this works only where
    /// the app publishes its text — the same apps where insertion goes through
    /// accessibility rather than a blind paste.
    private func harvestEdit() async {
        guard let edit = await inserter.editedSinceInsertion() else { return }
        await inserter.forgetInsertion()

        let learnedNow = await learned.learnFromInsertionEdit(
            inserted: edit.inserted, snapshot: edit.snapshot, current: edit.current)
        for correction in learnedNow {
            log("  LEARN  \"\(correction.heard)\" -> \"\(correction.intended)\" "
                + "(from your edit, seen \(correction.timesSeen)x)")
        }
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
        switch mode {
        case .lightTouch: return "light"
        case .fullRewrite: return "rewrite"
        case .code: return "code"
        }
    }

    private func rootMeanSquare(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(samples.count)).squareRoot()
    }
}
