import Foundation
import AppKit
import ApplicationServices

/// Inserts text into whatever application currently has focus.
///
/// Two mechanisms, because neither works everywhere:
///
/// * **Accessibility API** — the correct approach. Writes directly into the
///   focused text element. Fails in apps that do not expose settable AX text,
///   which includes many Electron apps and most terminals.
/// * **Synthesized ⌘V** — works almost everywhere, but borrows the pasteboard
///   and is blocked entirely by secure input.
///
/// Serialized as an actor: two dictations must never interleave insertions into
/// the same document.
public actor TextInserter {
    public enum InsertError: Error, Sendable, Equatable {
        case noFocusedElement
        /// A password field. Refused deliberately — never type into one.
        case secureField
        case focusChanged
        case pasteboardBusy
        case bothMethodsFailed(String)
    }

    public enum Method: String, Sendable {
        case accessibility
        case paste
    }

    /// Stamped on synthesized events so the hotkey tap ignores our own ⌘V
    /// instead of treating it as user input and aborting the dictation.
    public static let syntheticTag: Int64 = 0x464C4F57

    private let pasteboardMarker = "dev.kilanii.flowlocal.paste"

    public init() {}

    // MARK: - Entry point

    @discardableResult
    public func insert(_ text: String) throws -> Method {
        guard !text.isEmpty else { return .accessibility }

        // Never synthesize Return: in a chat app it sends the message, and in a
        // terminal it runs the command. A trailing newline is silently dropped.
        let payload = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .accessibility }

        let element = try focusedElement()
        try rejectSecureField(element)

        if insertViaAccessibility(element, text: payload) { return .accessibility }
        try insertViaPaste(payload)
        return .paste
    }

    // MARK: - Focus

    private func focusedElement() throws -> AXUIElement {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            system, kAXFocusedUIElementAttribute as CFString, &value)
        guard status == .success, let element = value else {
            throw InsertError.noFocusedElement
        }
        return unsafeBitCast(element, to: AXUIElement.self)
    }

    /// Password fields are identified by **subrole**, not role — they report
    /// role `AXTextField` like any other. Checking role alone would happily type
    /// a transcript into a password box.
    private func rejectSecureField(_ element: AXUIElement) throws {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXSubroleAttribute as CFString, &value) == .success,
            let subrole = value as? String
        else { return }
        if subrole == (kAXSecureTextFieldSubrole as String) {
            throw InsertError.secureField
        }
    }

    // MARK: - Accessibility path

    private func insertViaAccessibility(_ element: AXUIElement, text: String) -> Bool {
        // Probe first: writing to an unsettable attribute silently no-ops in
        // some apps, which looks like success and loses the text.
        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable) == .success,
            settable.boolValue
        else { return false }

        // Decide verifiability BEFORE writing. If the result cannot be confirmed
        // afterwards, do not write at all — an unverifiable AX write followed by
        // the paste fallback would insert the text twice. Observed for real:
        // Electron apps report the attribute settable, accept the write, return
        // success, and change nothing.
        guard let before = readValue(element) else { return false }

        let status = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFTypeRef)
        guard status == .success else { return false }

        guard let after = readValue(element) else { return false }
        return after != before && after.contains(text)
    }

    /// Full text of the focused element, or nil when the app does not expose it.
    private func readValue(_ element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &value) == .success
        else { return nil }
        if let string = value as? String { return string }
        if let attributed = value as? NSAttributedString { return attributed.string }
        return nil
    }

    // MARK: - Paste fallback

    private func insertViaPaste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let targetPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

        // Preserve whatever the user had. Promised/lazy items cannot be faithfully
        // restored, so only plain string content is saved — documented, not silently
        // best-effort.
        let saved = pasteboard.string(forType: .string)
        let savedChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(pasteboardMarker, forType: .init(pasteboardMarker))
        let ourChangeCount = pasteboard.changeCount

        defer {
            // Restore only if the pasteboard still holds our content. If the user
            // copied something in the meantime, theirs wins.
            if pasteboard.changeCount == ourChangeCount {
                pasteboard.clearContents()
                if let saved { pasteboard.setString(saved, forType: .string) }
            }
            _ = savedChangeCount
        }

        // Focus can move between transcription finishing and the paste landing.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            throw InsertError.focusChanged
        }

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw InsertError.bothMethodsFailed("could not create event source")
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents], state: .eventSuppressionStateSuppressionInterval)

        let vKey: CGKeyCode = 9  // "v"
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            throw InsertError.bothMethodsFailed("could not create key events")
        }

        down.flags = .maskCommand
        up.flags = .maskCommand
        // Tag both so our own event tap does not mistake this for the user
        // typing and abort the dictation mid-insert.
        down.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)
        up.setIntegerValueField(.eventSourceUserData, value: Self.syntheticTag)

        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)

        // Give the target app a moment to consume the pasteboard before restore.
        Thread.sleep(forTimeInterval: 0.12)
    }
}
