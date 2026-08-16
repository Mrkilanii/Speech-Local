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
