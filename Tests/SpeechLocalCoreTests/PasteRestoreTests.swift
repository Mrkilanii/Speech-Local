import Testing
@testable import SpeechLocalCore

/// The acceptance table's defaults: posted at 0, reads attributable, no AX
/// confirmation, change counts 7/7.
private func decide(
    now: Double,
    reads: [Double] = [],
    readsAttributable: Bool = true,
    axConfirmed: Bool = false,
    changeCount: Int = 7,
    ourChangeCount: Int = 7
) -> PasteRestore.Decision {
    PasteRestore.decide(
        now: now, postedAt: 0, reads: reads,
        readsAttributable: readsAttributable, axConfirmed: axConfirmed,
        changeCount: changeCount, ourChangeCount: ourChangeCount)
}

// MARK: - A read after ⌘V is evidence, but never before half a second

@Test func anEarlyReadStillWaitsForTheMinimumDelay() {
    #expect(decide(now: 0.3, reads: [0.05]) == .wait(until: 0.5))
}

@Test func anEarlyReadRestoresAtTheMinimumDelay() {
    #expect(decide(now: 0.5, reads: [0.05]) == .restore)
}

@Test func aLateReadIsGivenTimeToSettle() {
    #expect(decide(now: 0.5, reads: [0.45]) == .wait(until: 0.65))
}

@Test func aReadRestoresOnceSettled() {
    #expect(decide(now: 0.7, reads: [0.5]) == .restore)
}

// MARK: - No evidence

@Test func noReadWaitsForTheEvidenceWindow() {
    #expect(decide(now: 1.0, reads: []) == .wait(until: 2.0))
}

@Test func noReadByTheDeadlineKeepsTheTranscript() {
    #expect(decide(now: 2.0, reads: []) == .keepTranscript)
}

@Test func aReadBeforeThePasteIsNotEvidence() {
    #expect(decide(now: 0.6, reads: [-0.01]) == .wait(until: 2.0))
}

@Test func readsThatCannotBeAttributedAreNotEvidence() {
    #expect(decide(now: 2.0, reads: [0.05], readsAttributable: false) == .keepTranscript)
}

// MARK: - The field and the clipboard override the reads

@Test func theFieldShowingTheTextRestoresAtOnce() {
    #expect(decide(now: 0.1, axConfirmed: true) == .restore)
}

@Test func aNewCopyAbandonsTheRestoreEvenWhenConfirmed() {
    #expect(decide(now: 0.1, axConfirmed: true, changeCount: 8, ourChangeCount: 7) == .abandon)
}

// MARK: - The named residual

@Test func anUnattributedEarlyReaderIsIndistinguishableFromTheTarget() {
    // The residual named in the design: a clipboard reader that ignores the
    // transient marker and is not on the known list reads at 10 ms, before a
    // target slower than half a second. Its read looks exactly like the
    // target's, so this restores — and the slow target would paste the old
    // clipboard. Pinned so the gap stays visible; it cannot be closed here.
    #expect(decide(now: 0.5, reads: [0.01]) == .restore)
}

// MARK: - Reusing a pending snapshot

@Test func aPendingSnapshotIsReusedWhileTheClipboardIsStillOurs() {
    #expect(PasteRestore.reuseSnapshot(pendingOurChangeCount: 5, changeCount: 5))
}

@Test func aPendingSnapshotIsNotReusedAfterTheClipboardChanged() {
    #expect(!PasteRestore.reuseSnapshot(pendingOurChangeCount: 5, changeCount: 6))
}

@Test func withNoPendingRestoreThereIsNothingToReuse() {
    #expect(!PasteRestore.reuseSnapshot(pendingOurChangeCount: nil, changeCount: 5))
}
