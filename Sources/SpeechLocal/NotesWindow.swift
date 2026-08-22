import AppKit
import SwiftUI
import SpeechLocalCore

/// The meeting recorder: a real window you leave open, type into while a call
/// runs, and read the note in afterwards.
///
/// **A normal key window, unlike `DictationPanel`.** The panel must never
/// become key or text insertion breaks — it is a heads-up display over someone
/// else's document. This is the opposite: the user types their notes into it,
/// so it has to take focus. Two windows with opposite requirements, kept apart
/// on purpose.
@MainActor
final class NotesWindow {
    private var window: NSWindow?
    private let model: NotesModel

    init(model: NotesModel) { self.model = model }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Meeting Notes"
        window.contentView = NSHostingView(rootView: NotesView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SpeechLocalNotes")
        self.window = window

        Task { await model.refresh() }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    var isRecording: Bool { model.isRecording }

    func toggleRecording() { Task { await model.toggleRecording() } }
}

// MARK: - Model

@MainActor
final class NotesModel: ObservableObject {
    @Published var phase: MeetingSession.Phase = .idle
    @Published var elapsed: TimeInterval = 0
    @Published var transcript = ""
    @Published var notes = ""
    @Published var title = ""
    @Published var summary = ""
    @Published var progress: MeetingSummarizer.Progress?
    @Published var status: String?
    @Published var past: [Meeting] = []
    @Published var selected: Meeting?
    @Published var capturingSystemAudio = false

    private let asr: AppleASREngine
    private let capture: AudioCapture
    private let settingsStore: SettingsStore
    private let learned: LearnedCorrections
    private let store = MeetingStore()
    private let summariser = MeetingSummarizer()

    private var session: MeetingSession?
    private var tap: SystemAudioTap?
    private var ticker: Timer?
    private var current: Meeting?

    init(asr: AppleASREngine, capture: AudioCapture,
         settingsStore: SettingsStore, learned: LearnedCorrections) {
        self.asr = asr
        self.capture = capture
        self.settingsStore = settingsStore
        self.learned = learned
    }

    var isRecording: Bool { phase == .recording }

    func refresh() async { past = await store.all() }

    // MARK: Recording

    func toggleRecording() async {
        isRecording ? await stop() : await start()
    }

    func start() async {
        guard !isRecording else { return }
        summary = ""
        transcript = ""
        notes = ""
        title = ""
        progress = nil
        status = nil
        selected = nil

        // The other side of the call. Started per meeting rather than held
        // open: it is a system-wide tap, and there is no reason for it to exist
        // while nothing is being recorded.
        var systemBuffer: AudioRingBuffer?
        do {
            let tap = try SystemAudioTap()
            try tap.start()
            self.tap = tap
            systemBuffer = tap.buffer
            capturingSystemAudio = true
        } catch {
            // Mic-only is a working configuration, so this is a note, not a
            // failure. It is what the app did before this feature existed.
            capturingSystemAudio = false
            status = "Recording your microphone only — system audio unavailable (\(error))"
            log("  MEETING system audio unavailable: \(error)")
        }

        let meeting = Meeting()
        current = meeting

        let session = MeetingSession(
            engine: asr,
            buffer: capture.buffer,
            systemBuffer: systemBuffer,
            locale: settingsStore.current.locale,
            biasTerms: await learned.biasTerms())
        self.session = session
        await session.start()
        phase = .recording
        log("  MEETING started (system audio: \(capturingSystemAudio))")

        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    private func tick() async {
        guard let session else { return }
        elapsed = await session.elapsed
        transcript = await session.transcript
    }

    func stop() async {
        guard let session, isRecording else { return }
        phase = .finishing
        ticker?.invalidate()
        ticker = nil

        await session.stop()
        tap?.stop()
        tap = nil

        transcript = await session.transcript
        elapsed = await session.elapsed
        let lostAudio = await session.didLoseAudio
        self.session = nil
        log("  MEETING stopped — \(Int(elapsed))s, \(transcript.count) chars"
            + (lostAudio ? " (audio was lost to an overrun)" : ""))

        guard var meeting = current else { phase = .done; return }
        meeting.endedAt = Date()
        meeting.title = title
        meeting.notes = notes
        meeting.transcript = transcript
        await store.save(meeting)
        current = meeting
        await refresh()

        await summarise(meeting)
    }

    private func summarise(_ meeting: Meeting) async {
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            phase = .done
            status = "Nothing was said."
            return
        }

        phase = .summarising
        progress = MeetingSummarizer.Progress(stage: "Reading", done: 0, total: 1)
        do {
            let written = try await summariser.summarise(
                transcript: transcript,
                notes: notes,
                onProgress: { [weak self] update in
                    Task { @MainActor in self?.progress = update }
                })
            summary = written
            var saved = meeting
            saved.summary = written
            saved.notes = notes
            saved.title = title
            await store.save(saved)
            current = saved
            phase = .done
            progress = nil
            log("  MEETING summarised — \(written.count) chars")
            if settingsStore.current.autoFileMeetings { await fileToVault() }
        } catch {
            phase = .failed("\(error)")
            progress = nil
            status = "Could not summarise: \(error). The transcript is saved."
            log("  MEETING summary failed: \(error)")
        }
        await refresh()
    }

    // MARK: The vault

    func fileToVault() async {
        guard var meeting = current ?? selected else { return }
        meeting.notes = notes.isEmpty ? meeting.notes : notes
        meeting.title = title.isEmpty ? meeting.title : title

        guard let root = settingsStore.current.vaultURL else {
            status = "No vault found. Set one in Settings."
            return
        }
        do {
            let url = try VaultWriter(root: root).write(meeting)
            meeting.filedAt = url.path
            await store.save(meeting)
            current = meeting
            status = "Filed in \(url.lastPathComponent). Run the vault's ingest "
                + "skill to promote it into wiki/."
            log("  MEETING filed at \(url.path)")
            await refresh()
        } catch {
            status = "Could not file it: \(error)"
            log("  MEETING vault write failed: \(error)")
        }
    }

    func select(_ meeting: Meeting) {
        guard !isRecording else { return }
        selected = meeting
        current = meeting
        title = meeting.title
        notes = meeting.notes
        transcript = meeting.transcript
        summary = meeting.summary
        elapsed = meeting.duration
        phase = .done
        status = meeting.filedAt.map { "Filed at \($0)" }
    }

    func delete(_ meeting: Meeting) async {
        await store.delete(id: meeting.id)
        if selected?.id == meeting.id { selected = nil }
        await refresh()
    }
}
