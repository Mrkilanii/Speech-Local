import Testing
import Foundation
@testable import FlowLocalCore

// MARK: - The corpus itself

@Test func lightTouchCorpusPasses() {
    let failures = LightTouchInvariants.check()
    for failure in failures { Issue.record("\(failure)") }
    #expect(failures.isEmpty, "\(failures.count) regression(s)")
}

@Test func corpusPassesUnderBothCommaPolicies() {
    // The comma policy is user-selectable, so both settings must uphold the
    // invariants — a policy that eats words is not a valid choice to offer.
    for policy in [RulesCleanup.CommaPolicy.tidy, .sparse] {
        let failures = LightTouchInvariants.check(using: RulesCleanup(commaPolicy: policy))
        for failure in failures { Issue.record("[\(policy)] \(failure)") }
        #expect(failures.isEmpty, "\(policy) broke \(failures.count) case(s)")
    }
}

@Test func corpusIsSubstantial() {
    // A guard that shrinks silently stops guarding.
    #expect(LightTouchInvariants.corpus.count >= 15)
}

@Test func everyCaseIsDeterministic() {
    let engine = RulesCleanup()
    for testCase in LightTouchInvariants.corpus {
        let first = engine.apply(to: testCase.input)
        for _ in 0..<10 {
            #expect(engine.apply(to: testCase.input) == first, "nondeterministic: \(testCase.note)")
        }
    }
}

// MARK: - The detector that backs the corpus

@Test func detectorSpotsADroppedWord() {
    #expect(LightTouchInvariants.droppedContentWord(
        input: "we should ship it monday",
        output: "we should ship monday") == "it")
}

@Test func detectorAllowsFillerRemoval() {
    #expect(LightTouchInvariants.droppedContentWord(
        input: "um we should ship it", output: "We should ship it.") == nil)
}

@Test func detectorAllowsCollapsedDuplicate() {
    #expect(LightTouchInvariants.droppedContentWord(
        input: "send the the file", output: "Send the file.") == nil)
}

@Test func detectorAllowsStutterFragment() {
    #expect(LightTouchInvariants.droppedContentWord(
        input: "st stop the build", output: "Stop the build.") == nil)
}

@Test func detectorIsCleanOnIdentity() {
    let text = "the quick brown fox"
    #expect(LightTouchInvariants.droppedContentWord(input: text, output: text) == nil)
}

// MARK: - Load guard

@Test func loadReportsAPlausibleValue() {
    let load = SystemLoad.oneMinute()
    #expect(load >= 0)
    #expect(load < 500, "implausible load average — getloadavg misread")
}
