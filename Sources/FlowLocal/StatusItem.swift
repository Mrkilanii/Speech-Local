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

    init() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        lastLine = NSMenuItem(title: "No dictation yet", action: nil, keyEquivalent: "")

        let menu = NSMenu()
        menu.addItem(lastLine)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Hold Right Option — light-touch", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Hold Right Command — full rewrite", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(
            title: "Double-tap either — hands-free", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let quit = NSMenuItem(
            title: "Quit FlowLocal", action: #selector(quitPressed), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu

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

    @objc private func quitPressed() {
        onQuit?()
        NSApplication.shared.terminate(nil)
    }
}
