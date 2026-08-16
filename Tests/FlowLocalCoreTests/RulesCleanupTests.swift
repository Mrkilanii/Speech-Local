import Testing
@testable import FlowLocalCore

private let rules = RulesCleanup()

// MARK: - Filler removal

@Test func removesFillers() {
    #expect(rules.apply(to: "um so the thing is uh we should ship it monday i think")
            == "So the thing is we should ship it Monday I think.")
}

@Test(arguments: ["um", "uh", "erm", "umm", "hmm"])
func removesEachFiller(filler: String) {
    #expect(rules.apply(to: "\(filler) hello there") == "Hello there.")
}

@Test func keepsContextDependentWords() {
    // "like", "so", "right", "you know" carry meaning and must survive —
    // deleting them is the content loss this path exists to prevent.
    let input = "so like you know right we should actually do it"
    let out = rules.apply(to: input)
    for word in ["like", "you", "know", "right", "actually"] {
        #expect(out.lowercased().contains(word))
    }
}

// MARK: - Repetition

@Test func collapsesImmediateRepeats() {
    #expect(rules.apply(to: "send me the the file") == "Send me the file.")
}

@Test func keepsLegitimateDoubles() {
    // "had had" and "that that" are grammatical.
    #expect(rules.apply(to: "he had had enough").contains("had had"))
    #expect(rules.apply(to: "i know that that works").contains("that that"))
}

@Test func doesNotCollapseNonAdjacent() {
    let out = rules.apply(to: "the cat and the dog")
    #expect(out == "The cat and the dog.")
}

// MARK: - Capitalization and punctuation

@Test func capitalizesFirstWord() {
    #expect(rules.apply(to: "hello world") == "Hello world.")
}

@Test func capitalizesAfterSentenceEnd() {
    #expect(rules.apply(to: "one thing. another thing") == "One thing. Another thing.")
}

@Test func fixesStandaloneI() {
    #expect(rules.apply(to: "i think i can") == "I think I can.")
}

@Test func doesNotTouchIInsideWords() {
    #expect(rules.apply(to: "this is a big win") == "This is a big win.")
}

@Test func addsTerminalPeriod() {
    #expect(rules.apply(to: "ship it").hasSuffix("."))
}

@Test(arguments: ["done.", "really!", "why?"])
func preservesExistingTerminator(input: String) {
    #expect(rules.apply(to: input).hasSuffix(String(input.last!)))
}

@Test func replacesTrailingCommaWithPeriod() {
    #expect(rules.apply(to: "ship it,") == "Ship it.")
}

// MARK: - Determinism and safety

@Test func isDeterministic() {
    let input = "um so i think uh we should the the ship it monday"
    let first = rules.apply(to: input)
    for _ in 0..<20 { #expect(rules.apply(to: input) == first) }
}

@Test func neverReturnsEmptyForRealInput() {
    #expect(!rules.apply(to: "hello").isEmpty)
    #expect(!rules.apply(to: "the the the").isEmpty)
}

@Test(arguments: ["", "   ", "\n\t "])
func emptyInputStaysEmpty(input: String) {
    #expect(rules.apply(to: input).isEmpty)
}

@Test func preservesAllContentWords() {
    let input = "we need to fix the auth bug before friday or the audit fails"
    let out = rules.apply(to: input).lowercased()
    for word in input.split(separator: " ") {
        #expect(out.contains(word), "dropped '\(word)'")
    }
}

// MARK: - Content-loss guard

@Test func guardCatchesEmptyOutput() {
    #expect(RoutingCleanupEngine.contentLoss(
        original: "the patch completely killed performance and murdered our budget",
        output: "") == "empty output")
}

@Test func guardCatchesSevereTruncation() {
    let loss = RoutingCleanupEngine.contentLoss(
        original: "our counsel says the nda is unenforceable and we should countersue for damages",
        output: "Our counsel says")
    #expect(loss != nil)
}

@Test func guardCatchesDanglingConjunction() {
    // The exact observed failure: truncated mid-clause on "and".
    let loss = RoutingCleanupEngine.contentLoss(
        original: "our counsel says the nda is unenforceable and we should countersue for damages",
        output: "Our counsel says the NDA is unenforceable and")
    #expect(loss?.contains("mid-clause") == true)
}

@Test func guardAllowsLegitimateRewrite() {
    let loss = RoutingCleanupEngine.contentLoss(
        original: "so um i was thinking that maybe we could possibly consider shipping this on monday if thats okay",
        output: "I suggest we ship this on Monday.")
    #expect(loss == nil)
}

@Test func guardIgnoresVeryShortInput() {
    #expect(RoutingCleanupEngine.contentLoss(original: "ship it", output: "Ship.") == nil)
}

// MARK: - Comma handling

private let sparse = RulesCleanup(commaPolicy: .sparse)
private let tidy = RulesCleanup(commaPolicy: .tidy)

@Test func removesCommaStrandedByFillerRemoval() {
    // "um," loses its word but leaves the comma behind.
    #expect(rules.apply(to: "um, so we should ship it") == "So we should ship it.")
}

@Test func collapsesDoubledCommas() {
    // Mechanical repair, so the policy is pinned to .tidy — under .sparse the
    // comma is legitimately dropped for a different reason.
    #expect(tidy.apply(to: "we should, , ship it") == "We should, ship it.")
}

@Test func removesCommaBeforeTerminator() {
    #expect(rules.apply(to: "we should ship it,.") == "We should ship it.")
}

@Test func removesTrailingComma() {
    #expect(rules.apply(to: "we should ship it,") == "We should ship it.")
}

@Test func removesSpaceBeforeComma() {
    #expect(tidy.apply(to: "we should , ship it") == "We should, ship it.")
}

@Test func tidyKeepsOrdinaryCommas() {
    #expect(tidy.apply(to: "we should ship it, and then tell the team")
            == "We should ship it, and then tell the team.")
}

@Test func sparseDropsHesitationCommas() {
    // The reported problem: pausing mid-thought produced commas everywhere.
    #expect(sparse.apply(to: "i was thinking, that maybe, we should do it")
            == "I was thinking that maybe we should do it.")
}

@Test func sparseKeepsClauseCommas() {
    #expect(sparse.apply(to: "we should ship it, and then tell the team")
            == "We should ship it, and then tell the team.")
}

@Test func sparseKeepsCommaBeforeBut() {
    #expect(sparse.apply(to: "i wanted to, but i could not")
            == "I wanted to, but I could not.")
}

@Test func commaPolicyNeverDropsWords() {
    let input = "i was thinking, that maybe, we should ship it on monday"
    for engine in [rules, sparse] {
        let out = engine.apply(to: input).lowercased()
        for word in ["thinking", "maybe", "should", "ship", "monday"] {
            #expect(out.contains(word), "policy dropped '\(word)'")
        }
    }
}

@Test func sparseKeepsListCommas() {
    // Serial-comma lists have commas between items that are not clause markers;
    // dropping them collapses the list into a run-on phrase.
    #expect(sparse.apply(to: "we need apples, oranges, and pears")
            == "We need apples, oranges, and pears.")
}

@Test func sparseIsTheDefault() {
    #expect(RulesCleanup().apply(to: "i was thinking, that maybe, we should do it")
            == "I was thinking that maybe we should do it.")
}

// MARK: - Spurious sentence breaks from pauses

@Test func lowercasesStrayCapitalAfterPause() {
    // The reported bug: pausing produced a capital with no punctuation at all.
    #expect(rules.apply(to: "we should ship it Today")
            == "We should ship it today.")
}

@Test func lowercasesStrayCapitalOnAuxiliary() {
    #expect(rules.apply(to: "i think we Should do it")
            == "I think we should do it.")
}

@Test func keepsCapitalAfterRealFullStop() {
    // Punctuation is present, so the capital is justified — and a real sentence
    // break is indistinguishable from a pause-induced one, so it stands.
    #expect(rules.apply(to: "one thing. Another thing")
            == "One thing. Another thing.")
}

@Test func keepsProperNounCapitals() {
    #expect(rules.apply(to: "i spoke to Omar about it")
            == "I spoke to Omar about it.")
}

@Test func keepsAcronyms() {
    #expect(rules.apply(to: "send it to the NDA team").contains("NDA"))
}

@Test func doesNotMergeAfterAbbreviation() {
    #expect(rules.apply(to: "call Dr. Patel about it").contains("Dr."))
}

@Test func strayCapitalFixKeepsAllWords() {
    let input = "we should ship it Today and Then we tell them"
    let out = rules.apply(to: input).lowercased()
    for word in ["ship", "today", "then", "tell", "them"] {
        #expect(out.contains(word), "dropped '\(word)'")
    }
}
