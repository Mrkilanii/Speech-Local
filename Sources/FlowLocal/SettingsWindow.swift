import AppKit
import SwiftUI
import ServiceManagement
import FlowLocalCore

/// SwiftUI exports its own `Settings` scene type, so the model type is aliased
/// here rather than qualified at every use site.
typealias AppSettings = FlowLocalCore.Settings

/// Settings window. Opened from the menu bar; closing it does not quit the app.
@MainActor
final class SettingsWindow {
    private var window: NSWindow?
    private let model: SettingsModel

    init(store: SettingsStore, corrections: LearnedCorrections, history: TranscriptHistory) {
        model = SettingsModel(store: store, corrections: corrections, history: history)
    }

    /// Called when a change requires the hotkey tap to be rebuilt.
    var onHotkeysChanged: ((AppSettings) -> Void)? {
        get { model.onHotkeysChanged }
        set { model.onHotkeysChanged = newValue }
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FlowLocal Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window

        Task {
            await model.refreshCorrections()
            await model.refreshHistory()
            await model.loadLocales()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Model

@MainActor
final class SettingsModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var corrections: [Correction] = []
    @Published var newSpoken = ""
    @Published var newWritten = ""
    @Published var launchAtLoginError: String?

    private let store: SettingsStore
    private let correctionStore: LearnedCorrections
    private let historyStore: TranscriptHistory
    @Published var history: [TranscriptEntry] = []
    @Published var historyQuery = ""
    @Published var installedLocales: [String] = []
    @Published var supportedLocales: [String] = []
    @Published var localeStatus: String?
    @Published var isInstallingLocale = false
    @Published var localeToDownload = ""
    var onHotkeysChanged: ((AppSettings) -> Void)?

    init(store: SettingsStore, corrections: LearnedCorrections, history: TranscriptHistory) {
        self.store = store
        self.correctionStore = corrections
        self.historyStore = history
        self.settings = store.current
    }

    func refreshHistory() async {
        history = await historyStore.search(historyQuery)
    }

    func deleteHistory(_ entry: TranscriptEntry) async {
        await historyStore.delete(id: entry.id)
        await refreshHistory()
    }

    /// Disabling history destroys what was already captured. Leaving a hidden
    /// archive of someone's speech behind a toggle would be worse than useless.
    func setKeepHistory(_ enabled: Bool) {
        apply { $0.keepHistory = enabled }
        if !enabled {
            Task {
                await historyStore.clear()
                await refreshHistory()
            }
        }
    }

    func clearHistory() async {
        await historyStore.clear()
        await refreshHistory()
    }

    func loadLocales() async {
        installedLocales = await AppleASREngine.installedLocaleIdentifiers()
        supportedLocales = await AppleASREngine.allSupportedLocaleIdentifiers()
        if localeToDownload.isEmpty || installedLocales.contains(localeToDownload) {
            localeToDownload = downloadableLocales.first ?? ""
        }
    }

    /// Supported but not yet on the machine.
    var downloadableLocales: [String] {
        supportedLocales.filter { !installedLocales.contains($0) }
    }

    func isInstalled(_ identifier: String) -> Bool {
        installedLocales.contains(identifier)
    }

    func displayName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// Supported does not imply installed. Downloading is explicit rather than
    /// automatic: it is a network fetch, and this app's whole claim is that it
    /// does nothing over the network without being asked.
    func installLocale(_ identifier: String) async {
        isInstallingLocale = true
        localeStatus = "Downloading \(identifier)…"
        do {
            try await AppleASREngine.installAssets(for: identifier)
            await loadLocales()
            if isInstalled(identifier) {
                // Select it immediately: downloading a language is only ever
                // done in order to use it.
                apply { $0.locale = identifier }
                localeStatus = "\(displayName(identifier)) added and selected"
            } else {
                localeStatus = "\(identifier) reported installed but is not listed"
            }
        } catch {
            localeStatus = "Could not install \(identifier): \(error)"
        }
        isInstallingLocale = false
    }

    func apply(_ transform: (inout AppSettings) -> Void, hotkeysChanged: Bool = false) {
        var next = settings
        transform(&next)
        settings = store.update { $0 = next }
        if hotkeysChanged { onHotkeysChanged?(settings) }
    }

    func setLightTouchKey(_ key: HotkeyChoice) {
        var next = settings
        next.lightTouchKey = key
        next = next.resolvingConflicts(changed: \.lightTouchKey)
        settings = store.update { $0 = next }
        onHotkeysChanged?(settings)
    }

    func setFullRewriteKey(_ key: HotkeyChoice) {
        var next = settings
        next.fullRewriteKey = key
        next = next.resolvingConflicts(changed: \.fullRewriteKey)
        settings = store.update { $0 = next }
        onHotkeysChanged?(settings)
    }

    func addAlias() {
        let spoken = newSpoken.trimmingCharacters(in: .whitespaces).lowercased()
        let written = newWritten.trimmingCharacters(in: .whitespaces)
        guard !spoken.isEmpty, !written.isEmpty else { return }
        apply { $0.aliases[spoken] = written }
        newSpoken = ""
        newWritten = ""
    }

    func removeAlias(_ spoken: String) {
        apply { $0.aliases.removeValue(forKey: spoken) }
    }

    func refreshCorrections() async {
        corrections = await correctionStore.all()
    }

    func forget(_ correction: Correction) async {
        await correctionStore.forget(heard: correction.heard, intended: correction.intended)
        await refreshCorrections()
    }

    /// Registering can fail (unsigned builds, MDM policy), so the result is
    /// surfaced rather than silently leaving the toggle in a lying state.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
            apply { $0.launchAtLogin = enabled }
        } catch {
            launchAtLoginError = "\(error.localizedDescription)"
            settings = store.current   // revert the toggle to the truth
        }
    }
}

// MARK: - View

private struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            vocabulary.tabItem { Label("Vocabulary", systemImage: "text.book.closed") }
            learned.tabItem { Label("Learned", systemImage: "brain") }
            historyTab.tabItem { Label("History", systemImage: "clock") }
        }
        .frame(width: 460, height: 520)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Hotkeys") {
                Picker("Light-touch", selection: Binding(
                    get: { model.settings.lightTouchKey },
                    set: { model.setLightTouchKey($0) }
                )) {
                    ForEach(HotkeyChoice.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Picker("Full rewrite", selection: Binding(
                    get: { model.settings.fullRewriteKey },
                    set: { model.setFullRewriteKey($0) }
                )) {
                    ForEach(HotkeyChoice.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text("Hold to dictate, or double-tap for hands-free. "
                     + "Choosing a key the other gesture uses moves that one aside.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Language") {
                Picker("Dictation language", selection: Binding(
                    get: { model.settings.locale },
                    set: { locale in model.apply { $0.locale = locale } }
                )) {
                    ForEach(model.installedLocales, id: \.self) { identifier in
                        Text(model.displayName(identifier)).tag(identifier)
                    }
                }

                // Only downloaded languages are offered above: choosing one that
                // is merely "supported" would fail at transcription time with
                // nothing to explain why.
                if !model.downloadableLocales.isEmpty {
                    HStack {
                        Picker("Download language", selection: $model.localeToDownload) {
                            ForEach(model.downloadableLocales, id: \.self) { identifier in
                                Text(model.displayName(identifier)).tag(identifier)
                            }
                        }
                        Button(model.isInstallingLocale ? "Downloading…" : "Download") {
                            Task { await model.installLocale(model.localeToDownload) }
                        }
                        .disabled(model.isInstallingLocale || model.localeToDownload.isEmpty)
                    }
                    Text("Downloaded languages are added above and selected "
                         + "automatically. \(model.downloadableLocales.count) more "
                         + "available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let status = model.localeStatus {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }

                Text("Cleanup rules — filler words, contractions, capitalisation "
                     + "— exist for English and Arabic only. Other languages are "
                     + "transcribed and punctuated by the recognizer, then left "
                     + "alone rather than run through rules that would mangle them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cleanup") {
                Picker("Punctuation", selection: Binding(
                    get: { model.settings.commaPolicy },
                    set: { policy in model.apply { $0.commaPolicy = policy } }
                )) {
                    ForEach(CommaChoice.allCases, id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                Text("Apple's transcriber adds a comma wherever you pause. "
                     + "\"Only grammatical commas\" keeps those that join clauses "
                     + "or separate list items, and drops the rest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Play start and stop sounds", isOn: Binding(
                    get: { model.settings.playSounds },
                    set: { on in model.apply { $0.playSounds = on } }
                ))
                Toggle("Keep transcript history", isOn: Binding(
                    get: { model.settings.keepHistory },
                    set: { model.setKeepHistory($0) }
                ))
                Toggle("Launch at login", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let error = model.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Vocabulary

    private var vocabulary: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Words the transcriber gets wrong, and what they should be.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                TextField("heard as…", text: $model.newSpoken)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("write as…", text: $model.newWritten)
                Button("Add") { model.addAlias() }
                    .disabled(model.newSpoken.isEmpty || model.newWritten.isEmpty)
            }
            .textFieldStyle(.roundedBorder)

            List {
                ForEach(model.settings.aliases.sorted(by: { $0.key < $1.key }), id: \.key) { pair in
                    HStack {
                        Text(pair.key).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text(pair.value)
                        Spacer()
                        Button {
                            model.removeAlias(pair.key)
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if model.settings.aliases.isEmpty {
                    Text("No vocabulary yet").foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
    }

    // MARK: History

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your last \(TranscriptHistory.maximumEntries) dictations, stored "
                 + "only on this Mac. Turning history off in General deletes them.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                TextField("Search", text: $model.historyQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.refreshHistory() } }
                Button("Search") { Task { await model.refreshHistory() } }
                Button("Clear all") { Task { await model.clearHistory() } }
            }

            List {
                ForEach(model.history) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.date, style: .time)
                                .font(.caption2).foregroundStyle(.tertiary)
                            if let app = entry.appName {
                                Text(app).font(.caption2).foregroundStyle(.tertiary)
                            }
                            if entry.mode == .fullRewrite {
                                Text("rewrite").font(.caption2).foregroundStyle(.purple)
                            }
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.cleaned, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                            Button {
                                Task { await model.deleteHistory(entry) }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                        }
                        Text(entry.cleaned).font(.system(size: 12)).lineLimit(3)
                    }
                    .padding(.vertical, 2)
                }
            }
            .overlay {
                if model.history.isEmpty {
                    Text(model.settings.keepHistory ? "No dictations yet" : "History is off")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding()
    }

    // MARK: Learned

    private var learned: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Corrections FlowLocal picked up from \"Fix last dictation…\". "
                 + "These bias the recognizer, and repair text once seen twice.")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(model.corrections, id: \.heard) { correction in
                    HStack {
                        Text(correction.heard).foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption2).foregroundStyle(.tertiary)
                        Text(correction.intended.isEmpty ? "(removed)" : correction.intended)
                            .italic(correction.intended.isEmpty)
                        Spacer()
                        Text("×\(correction.timesSeen)")
                            .font(.caption).foregroundStyle(.tertiary)
                        Button {
                            Task { await model.forget(correction) }
                        } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if model.corrections.isEmpty {
                    Text("Nothing learned yet").foregroundStyle(.tertiary)
                }
            }

            Button("Refresh") { Task { await model.refreshCorrections() } }
        }
        .padding()
    }
}
