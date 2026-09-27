import Foundation

/// Refuses to put dictated text where a password goes.
///
/// A dictation was pasted into a macOS administrator prompt three times. That
/// prompt belongs to SecurityAgent, and knowing whose window it is does not
/// depend on the prompt describing its field correctly — so the app is checked
/// before the field.
///
/// Three signals, in order of how certain they are:
///
/// 1. **The frontmost app is a system authentication process.** Anything typed
///    there is a password.
/// 2. **The focused element is a secure text field.** The field says so itself.
/// 3. **Secure input is on.** Some app has asked for keystrokes to be hidden —
///    usually a password field, sometimes a terminal's Secure Keyboard Entry. A
///    synthesized ⌘V would be blocked anyway, so refusing costs nothing there
///    and offers Copy instead.
///
/// Other authentication prompts may not be covered by the two bundle IDs; that
/// is a known gap, not an oversight.
public enum InsertionGuard {
    public enum Verdict: Sendable, Equatable {
        case allow
        case refuse(Reason)
    }

    public enum Reason: Sendable, Equatable {
        case systemAuthentication
        case secureField
        case secureInput
    }

    /// Lowercased: bundle IDs are compared without regard to case, and
    /// SecurityAgent reports itself as `com.apple.SecurityAgent`.
    static let authenticationBundleIDs: Set<String> = [
        "com.apple.securityagent",
        "com.apple.loginwindow",
    ]

    static let secureTextFieldSubrole = "AXSecureTextField"

    /// Safe to call with only the bundle ID known — at key release, before any
    /// audio is transcribed — by passing `false` and `nil` for the rest.
    public static func check(
        bundleID: String?,
        secureInputEnabled: Bool,
        focusedSubrole: String?
    ) -> Verdict {
        if let bundleID, authenticationBundleIDs.contains(bundleID.lowercased()) {
            return .refuse(.systemAuthentication)
        }
        if focusedSubrole == secureTextFieldSubrole {
            return .refuse(.secureField)
        }
        if secureInputEnabled {
            return .refuse(.secureInput)
        }
        return .allow
    }
}
