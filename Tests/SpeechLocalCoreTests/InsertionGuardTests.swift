import Testing
@testable import SpeechLocalCore

// MARK: - Refused

@Test func theAdministratorPromptIsRefused() {
    // Reported as mixed case; the comparison must not care.
    #expect(InsertionGuard.check(
        bundleID: "com.apple.SecurityAgent", secureInputEnabled: false, focusedSubrole: nil)
        == .refuse(.systemAuthentication))
}

@Test func theLoginWindowIsRefusedAsAuthenticationNotSecureInput() {
    #expect(InsertionGuard.check(
        bundleID: "com.apple.loginwindow", secureInputEnabled: true, focusedSubrole: nil)
        == .refuse(.systemAuthentication))
}

@Test func aSecureTextFieldIsRefusedAsAFieldNotSecureInput() {
    #expect(InsertionGuard.check(
        bundleID: "com.apple.Safari", secureInputEnabled: true, focusedSubrole: "AXSecureTextField")
        == .refuse(.secureField))
}

@Test func secureInputAloneIsRefused() {
    // Terminal with Secure Keyboard Entry on.
    #expect(InsertionGuard.check(
        bundleID: "com.apple.Terminal", secureInputEnabled: true, focusedSubrole: nil)
        == .refuse(.secureInput))
}

// MARK: - Allowed

@Test func anOrdinaryTextAreaIsAllowed() {
    #expect(InsertionGuard.check(
        bundleID: "com.anthropic.claudefordesktop", secureInputEnabled: false, focusedSubrole: "AXTextArea")
        == .allow)
}

@Test func nothingKnownIsAllowed() {
    #expect(InsertionGuard.check(bundleID: nil, secureInputEnabled: false, focusedSubrole: nil) == .allow)
}
