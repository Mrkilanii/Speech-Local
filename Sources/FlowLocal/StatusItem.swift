import AppKit
import FlowLocalCore

/// Menu-bar indicator.
///
/// Exists because M2's first live test "failed" purely for lack of feedback:
/// every gesture worked, but the app was invisible, so there was no way to know.
/// A dictation tool must always show whether it is listening — that is not
/// polish, it is the difference between usable and not.
@MainActor
final class StatusItem {
    enum State {
        case idle
        case recording(CleanupMode)
        case processing
        case error(String)

        var symbol: String {
            switch self {
            case .idle:                    return "mic"
            case .recording(.lightTouch):  return "mic.fill"
            case .recording(.fullRewrite): return "wand.and.stars"
            case .processing:              return "ellipsis.circle"
            case .error:                   return "exclamationmark.triangle"
            }
        }

        var tooltip: String {
            switch self {
            case .idle:                    return "FlowLocal — ready"
            case .recording(.lightTouch):  return "Recording (light-touch)"
            case .recording(.fullRewrite): return "Recording (full rewrite)"
            case .processing:              return "Processing…"
            case .error(let why):          return "FlowLocal — \(why)"
            }
        }
    }

    private let item: NSStatusItem
    private var lastLine: NSMenuItem

    var onQuit: (() -> Void)?
    var onCorrect: (() -> Void)?
    var onSettings: (() -> Void)?
    private var correctItem: NSMenuItem!

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lastLine = NSMenuItem(title: "No dictation yet", action: nil, keyEquivalent: "")

        let menu = NSMenu()
        menu.addItem(lastLine)
        correctItem = NSMenuItem(
            title: "Fix last dictation…", action: #selector(correctPressed), keyEquivalent: "")
        correctItem.isEnabled = false
        menu.addItem(correctItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Hold Right Option — light-touch", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Hold Right Command — full rewrite", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Double-tap either — hands-free", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let settings = NSMenuItem(
            title: "Settings…", action: #selector(settingsPressed), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(
            title: "Quit FlowLocal", action: #selector(quitPressed), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.autoenablesItems = false
        item.menu = menu
        correctItem.target = self

        apply(.idle)
    }

    func apply(_ state: State) {
        item.button?.image = NSImage(
            systemSymbolName: state.symbol, accessibilityDescription: state.tooltip)
        item.button?.toolTip = state.tooltip
    }

    /// Shows the outcome of the last dictation, so the menu is a usable record
    /// rather than a decoration.
    func report(_ line: String) {
        lastLine.title = line
    }

    /// Audible confirmation. A hotkey app is often used while looking at another
    /// window, where a menu-bar glyph change goes unseen.
    func chime(start: Bool) {
        NSSound(named: start ? "Tink" : "Pop")?.play()
    }

    /// Enabled only once there is something to correct.
    func allowCorrection(_ allowed: Bool) {
        correctItem.isEnabled = allowed
    }

    /// Prompts for the corrected text, seeded with what was produced.
    /// Returns nil if the user cancels or changes nothing.
    func askForCorrection(original: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Fix this dictation"
        alert.informativeText = "Correct any misheard words. FlowLocal learns "
            + "them and will bias future recognition toward them."
        alert.addButton(withTitle: "Learn")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = original
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let edited = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return edited.isEmpty || edited == original ? nil : edited
    }

    @objc private func correctPressed() {
        onCorrect?()
    }

    @objc private func settingsPressed() {
        onSettings?()
    }

    @objc private func quitPressed() {
        onQuit?()
        NSApplication.shared.terminate(nil)
    }
}
