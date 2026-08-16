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
        /// Something is focused, but it cannot accept text — the desktop, a
        /// button, a web page with no input selected.
        case noTextInput
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

    /// Detailed description of the focused element. Diagnostics only — used to
    /// find a signal that separates "caret in an editable field" from "a
    /// container that merely advertises text attributes".
    public func describeFocus() -> String {
        let frontmost = NSWorkspace.shared.frontmostApplication
        guard let element = try? focusedElement() else {
            return "none app=\(frontmost?.localizedName ?? "?") "
                + "bundle=\(frontmost?.bundleIdentifier ?? "?") "
                + "desktop=\(Self.isDesktop(frontmost))"
        }

        func string(_ attribute: String) -> String? {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success else { return nil }
            return value as? String
        }
        func settable(_ attribute: String) -> Bool {
            var flag: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(
                element, attribute as CFString, &flag) == .success && flag.boolValue
        }
        func present(_ attribute: String) -> Bool {
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(
                element, attribute as CFString, &value) == .success && value != nil
        }

        // A real caret reports a concrete location; a container often does not.
        var rangeText = "nil"
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
           let rangeRef = rangeValue {
            var range = CFRange()
            if AXValueGetValue(unsafeBitCast(rangeRef, to: AXValue.self), .cfRange, &range) {
                rangeText = "loc=\(range.location) len=\(range.length)"
            } else {
                rangeText = "unreadable"
            }
        }

        var focusedFlag = "?"
        var focusedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element, kAXFocusedAttribute as CFString, &focusedValue) == .success {
            focusedFlag = "\((focusedValue as? Bool) ?? false)"
        }

        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        return """
        app=\(app) role=\(string(kAXRoleAttribute as String) ?? "?") \
        subrole=\(string(kAXSubroleAttribute as String) ?? "-") \
        focused=\(focusedFlag) range=\(rangeText) \
        valueRead=\(present(kAXValueAttribute as String)) \
        valueSet=\(settable(kAXValueAttribute as String)) \
        selTextSet=\(settable(kAXSelectedTextAttribute as String)) \
        numChars=\(present(kAXNumberOfCharactersAttribute as String)) \
        accepts=\(acceptsText(element))
        """.replacingOccurrences(of: "\n", with: "")
    }

    @discardableResult
    public func insert(_ text: String) throws -> Method {
        guard !text.isEmpty else { return .accessibility }

        // Never synthesize Return: in a chat app it sends the message, and in a
        // terminal it runs the command. A trailing newline is silently dropped.
        let payload = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !payload.isEmpty else { return .accessibility }

        // Three distinguishable states, and only the middle one refuses:
        //
        //   1. No AX element at all      -> paste blind. The app publishes no
        //                                   accessibility state (terminals, the
        //                                   Codex app, many custom surfaces).
        //                                   Refusing here was wrong: pressing the
        //                                   hotkey and speaking IS the intent.
        //   2. An element that cannot     -> offer Copy. This is the "clicked off
        //      take text                     the text box" case, and it reports a
        //                                   non-editable role such as AXGroup.
        //   3. An editable element        -> insert normally.
        //
        // Only the desktop is excluded from (1): with Finder frontmost and
        // nothing focused, there is genuinely nowhere for a paste to go.
        guard let element = try? focusedElement() else {
            guard !Self.isDesktop(NSWorkspace.shared.frontmostApplication) else {
                throw InsertError.noTextInput
            }
            try insertViaPaste(payload)
            return .paste
        }

        try rejectSecureField(element)

        // Checked before either mechanism runs. Posting ⌘V at something that
        // cannot take text still "succeeds": the keystroke is delivered, nothing
        // happens, and the clipboard is then restored — silently destroying the
        // transcript. The caller needs to know so it can offer the text instead.
        guard acceptsText(element) else { throw InsertError.noTextInput }

        if insertViaAccessibility(element, text: payload) { return .accessibility }
        try insertViaPaste(payload)
        return .paste
    }

    /// Apps that accept ⌘V but expose no focused AX element.
    ///
    /// Terminals are the obvious members — they render their own text surface
    /// and publish nothing through accessibility — but the category is broader
    /// than that. The Codex desktop app (`com.openai.codex`) also reports no
    /// focused element while pasting perfectly, which is why this list is keyed
    /// on "no AX focus, paste works" rather than on being a terminal.
    ///
    /// For these, `focusedElement()` throws before any capability check runs, so
    /// they must be recognised up front or they can never be dictated into.
    static let pasteOnlyBundleIDs: Set<String> = [
        // No-AX-focus apps that are not terminals.
        "com.openai.codex",
        // Terminals.
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp-Preview",
        "com.mitchellh.ghostty",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.raycast.macos",
    ]

    /// Finder frontmost with nothing focused means the desktop: no paste target.
    static func isDesktop(_ app: NSRunningApplication?) -> Bool {
        app?.bundleIdentifier == "com.apple.finder" || app == nil
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

    /// Whether the focused element can receive typed text **right now**.
    ///
    /// The signal is **settability**, established by comparing the two states in
    /// the same app:
    ///
    /// | | role | valueSet | selTextSet |
    /// |---|---|---|---|
    /// | caret in the field | `AXTextArea` | true | true |
    /// | clicked off the field | `AXGroup` | false | false |
    ///
    /// Note what is *not* usable: `kAXSelectedTextRangeAttribute` reads back
    /// `loc=0 len=0` in both states, and both report `focused=true`. Earlier
    /// versions keyed on the range and therefore accepted a container that had
    /// nowhere to put text — ⌘V was delivered, discarded, and the clipboard
    /// restored over the transcript.
    private func acceptsText(_ element: AXUIElement) -> Bool {
        func settable(_ attribute: String) -> Bool {
            var flag: DarwinBoolean = false
            return AXUIElementIsAttributeSettable(
                element, attribute as CFString, &flag) == .success && flag.boolValue
        }
        if settable(kAXSelectedTextAttribute as String)
            || settable(kAXValueAttribute as String) { return true }

        // Terminals (Terminal.app, iTerm, and CLI tools running in them, such as
        // Codex) expose their text as READ-ONLY: nothing is settable, yet ⌘V
        // works perfectly. Settability alone therefore refuses them.
        //
        // Falling back to role is safe here because the case that motivated the
        // strict check — clicking off a text box — reports `AXGroup`, which is
        // deliberately absent from this list.
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXRoleAttribute as CFString, &roleValue) == .success,
            let role = roleValue as? String
        else { return false }

        return [
            kAXTextAreaRole as String,
            kAXTextFieldRole as String,
            kAXComboBoxRole as String,
            "AXSearchField",
        ].contains(role)
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
