import Testing
@testable import SpeechLocalCore

// The gesture machine is pure, so real timings are simulated exactly rather
// than slept through.

private func machine() -> HotkeyGesture {
    var g = HotkeyGesture()
    g.holdThreshold = 0.25
    g.doubleTapWindow = 0.35
    g.maxToggleDuration = 300
    return g
}

// MARK: - Hold

@Test func holdBeginsRecordingImmediately() {
    var g = machine()
    #expect(g.handle(.keyDown(at: 0)) == .beginRecording(.hold))
    #expect(g.isRecording)
}

@Test func holdPastThresholdThenReleaseFinishes() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    #expect(g.handle(.tick(at: 0.30)) == .none)      // hold confirmed
    #expect(g.state == .holding)
    #expect(g.handle(.keyUp(at: 2.0)) == .finishRecording(.hold))
    #expect(!g.isRecording)
}

@Test func longPressReleasedWithoutTickStillFinishes() {
    // A release can arrive before any tick fires; duration alone must classify it.
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    #expect(g.handle(.keyUp(at: 0.9)) == .finishRecording(.hold))
}

// MARK: - Short tap resolving to a hold

@Test func quickTapWaitsBeforeCommitting() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    // Released fast — could still become a double-tap, so nothing is emitted.
    #expect(g.handle(.keyUp(at: 0.10)) == .none)
    #expect(g.isRecording, "audio must be retained while the verdict is pending")
}

@Test func quickTapBecomesHoldWhenWindowExpires() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    #expect(g.handle(.tick(at: 0.30)) == .none)       // still inside the window
    #expect(g.handle(.tick(at: 0.50)) == .finishRecording(.hold))
    #expect(!g.isRecording)
}

// MARK: - Double-tap toggle

@Test func doubleTapDiscardsAndLatches() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    // Second tap inside the window: the first capture was never wanted.
    #expect(g.handle(.keyDown(at: 0.25)) == .discardAndRestart)
    #expect(g.state == .toggled)
    #expect(g.isRecording)
}

@Test func toggleStopsOnNextPress() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    _ = g.handle(.keyDown(at: 0.25))
    #expect(g.handle(.keyDown(at: 30)) == .finishRecording(.toggle))
    #expect(!g.isRecording)
}

@Test func toggleSurvivesKeyUpOfTheLatchingTap() {
    // Releasing the second tap must not end a hands-free session.
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    _ = g.handle(.keyDown(at: 0.25))
    #expect(g.handle(.keyUp(at: 0.30)) == .none)
    #expect(g.state == .toggled)
}

@Test func lateSecondTapIsANewGestureNotAToggle() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    // Beyond the window: finish the first, begin a second.
    #expect(g.handle(.keyDown(at: 0.80)) == .finishRecording(.hold))
    #expect(g.state == .pendingFirstPress(downAt: 0.80))
}

@Test func toggleEndsAtMaxDuration() {
    var g = machine()
    g.maxToggleDuration = 10
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    _ = g.handle(.keyDown(at: 0.25))
    #expect(g.handle(.tick(at: 5)) == .none)
    #expect(g.handle(.tick(at: 11)) == .finishRecording(.toggle))
}

// MARK: - Autorepeat

@Test func autorepeatIsIgnored() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    for _ in 0..<50 { #expect(g.handle(.keyRepeat) == .none) }
    #expect(g.handle(.keyUp(at: 1.0)) == .finishRecording(.hold))
}

@Test func autorepeatDoesNotDisturbIdle() {
    var g = machine()
    #expect(g.handle(.keyRepeat) == .none)
    #expect(g.state == .idle)
}

// MARK: - Abort

@Test func abortWhileHoldingFinishes() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.tick(at: 0.30))
    #expect(g.abort() == .finishRecording(.hold))
    #expect(g.state == .idle)
}

@Test func abortWhileToggledFinishesAsToggle() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.handle(.keyUp(at: 0.10))
    _ = g.handle(.keyDown(at: 0.25))
    #expect(g.abort() == .finishRecording(.toggle))
}

@Test func abortWhenIdleDoesNothing() {
    var g = machine()
    #expect(g.abort() == .none)
}

@Test func abortIsIdempotent() {
    var g = machine()
    _ = g.handle(.keyDown(at: 0))
    _ = g.abort()
    #expect(g.abort() == .none)
}

// MARK: - Sequences

@Test func consecutiveHoldsAreIndependent() {
    var g = machine()
    for i in 0..<3 {
        let base = Double(i) * 10
        #expect(g.handle(.keyDown(at: base)) == .beginRecording(.hold))
        #expect(g.handle(.keyUp(at: base + 1)) == .finishRecording(.hold))
    }
}

@Test func strayKeyUpIsHarmless() {
    var g = machine()
    #expect(g.handle(.keyUp(at: 1)) == .none)
    #expect(g.state == .idle)
}
