import Testing
import Foundation
@testable import FlowLocalCore

/// Each test gets its own store so nothing touches the real corrections file.
private func freshStore() -> LearnedCorrections {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-test-\(UUID().uuidString).json")
    return LearnedCorrections(storeURL: url)
}

// MARK: - Learning from an edit

@Test func learnsSingleWordSubstitution() async {
    let store = freshStore()
    // The real case: "ship" heard as "tip".
    let learned = await store.learnFromEdit(
        raw: "we should tip it on monday",
        corrected: "we should ship it on monday")
    #expect(learned.count == 1)
    #expect(learned.first?.heard == "tip")
    #expect(learned.first?.intended == "ship")
    #expect(learned.first?.before == "should")
    #expect(learned.first?.after == "it")
}

@Test func learnsNothingWhenTextIsUnchanged() async {
    let store = freshStore()
    let learned = await store.learnFromEdit(
        raw: "we should ship it", corrected: "we should ship it")
    #expect(learned.isEmpty)
}

@Test func ignoresEditsThatChangeWordCount() async {
    // Insertions/deletions are the user rewriting their own words, not fixing a
    // misrecognition. Learning from them would poison the store.
    let store = freshStore()
    let learned = await store.learnFromEdit(
        raw: "we should tip it",
        corrected: "we should probably ship it today")
    #expect(learned.isEmpty)
}

@Test func learnsMultipleSubstitutionsInOneEdit() async {
    let store = freshStore()
    let learned = await store.learnFromEdit(
        raw: "send the tip to bob", corrected: "send the ship to rob")
    #expect(learned.count == 2)
}

@Test func repeatedCorrectionIncrementsEvidence() async {
    let store = freshStore()
    _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    let second = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    #expect(second.first?.timesSeen == 2)
    #expect(await store.count() == 1, "identical corrections must merge, not duplicate")
}

// MARK: - Biasing

@Test func biasTermsAvailableAfterOneCorrection() async {
    // Biasing is safe, so it applies immediately — no threshold.
    let store = freshStore()
    _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    #expect(await store.biasTerms() == ["ship"])
}

@Test func biasTermsAreDeduplicated() async {
    let store = freshStore()
    _ = await store.learnFromEdit(raw: "the tip is ready", corrected: "the ship is ready")
    _ = await store.learnFromEdit(raw: "a tip arrived", corrected: "a ship arrived")
    #expect(await store.biasTerms() == ["ship"])
}

// MARK: - Substitution requires evidence AND context

@Test func doesNotSubstituteBeforeThreshold() async {
    let store = freshStore()
    _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    // Seen once; substitution needs two.
    #expect(await store.repair("we should tip it now") == "we should tip it now")
}

@Test func substitutesOnceThresholdIsMet() async {
    let store = freshStore()
    for _ in 0..<2 {
        _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    }
    #expect(await store.repair("we should tip it now") == "we should ship it now")
}

@Test func doesNotFireInDifferentContext() async {
    // The whole point: "tip" was corrected after "should", so a genuine "tip"
    // elsewhere must survive untouched.
    let store = freshStore()
    for _ in 0..<2 {
        _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    }
    let out = await store.repair("please leave a tip for the driver")
    #expect(out == "please leave a tip for the driver")
}

@Test func preservesPunctuationWhenSubstituting() async {
    let store = freshStore()
    for _ in 0..<2 {
        _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    }
    #expect(await store.repair("we should tip it.") == "we should ship it.")
}

@Test func repairIsIdentityWithEmptyStore() async {
    let store = freshStore()
    let text = "nothing here should change at all"
    #expect(await store.repair(text) == text)
}

// MARK: - Forgetting and persistence

@Test func forgetRemovesACorrection() async {
    let store = freshStore()
    for _ in 0..<2 {
        _ = await store.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    }
    await store.forget(heard: "tip", intended: "ship")
    #expect(await store.count() == 0)
    #expect(await store.repair("we should tip it") == "we should tip it")
}

@Test func correctionsSurviveReload() async {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-persist-\(UUID().uuidString).json")
    let first = LearnedCorrections(storeURL: url)
    for _ in 0..<2 {
        _ = await first.learnFromEdit(raw: "we should tip it", corrected: "we should ship it")
    }

    // A new instance reading the same file is what happens on next launch.
    let second = LearnedCorrections(storeURL: url)
    #expect(await second.count() == 1)
    #expect(await second.repair("we should tip it") == "we should ship it")
}
