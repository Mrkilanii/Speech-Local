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

    init(store: SettingsStore, corrections: LearnedCorrections) {
        model = SettingsModel(store: store, corrections: corrections)
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

        Task { await model.refreshCorrections() }
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
    var onHotkeysChanged: ((AppSettings) -> Void)?

    init(store: SettingsStore, corrections: LearnedCorrections) {
        self.store = store
        self.correctionStore = corrections
        self.settings = store.current
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
