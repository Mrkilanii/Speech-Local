import Testing
@testable import SpeechLocalCore

// MARK: - The acceptance table (Phase 4)

@Test(arguments: [
    ("Where, like, there is no difference", "Where there is no difference"),
    ("Like, don't give me a hint yet.", "don't give me a hint yet."),
    ("So, like, you know, we ship.", "So we ship."),
    ("Wait. You know, it works.", "Wait. it works."),
    ("I like, you know, apples.", "I like apples."),
])
func aFencedDiscourseMarkerIsRemoved(input: String, expected: String) {
    #expect(DiscourseFillers.apply(input) == expected)
}

@Test func likeMeaningSuchAsIsRemovedAnyway() {
    // Accepted misfire: here "like" means "such as", and the commas look
    // exactly like a filler's. Pinned so the cost of the rule stays visible.
    #expect(DiscourseFillers.apply("fruits, like, apples and pears")
            == "fruits apples and pears")
}

@Test(arguments: [
    // Not opening a clause: "would" has no punctuation after it.
    "I would like, if possible, a table.",
    // No commas at all — the recognizer heard no pause.
    "so like you know right we should actually do it",
    // Nothing follows the phrase.
    "It was fine, like,",
    // "you" does not open a clause; "know" before it has no comma.
    "I know you know, right?",
])
func anUnfencedMarkerIsLeftAlone(input: String) {
    #expect(DiscourseFillers.apply(input) == input)
}

@Test func punctuationInsideThePhraseBlocksIt() {
    // Quoted or bracketed, the words are being talked about, not filled with.
    #expect(DiscourseFillers.apply("So, you \"know,\" it works")
            == "So, you \"know,\" it works")
    #expect(DiscourseFillers.apply("So, \"like,\" it works")
            == "So, \"like,\" it works")
}

// MARK: - Case

@Test func matchingIgnoresCase() {
    #expect(DiscourseFillers.apply("LIKE, it works") == "it works")
    #expect(DiscourseFillers.apply("Right, You Know, it works") == "Right it works")
}

// MARK: - The light-touch promise

@Test func everyCorpusInputPassesThroughUnchanged() {
    // The Backtrack stage runs before RulesCleanup, so the corpus guard in
    // LightTouchInvariants never sees this stage. It has to hold the same line
    // on its own: none of the corpus inputs fences a marker off with commas.
    for testCase in LightTouchInvariants.corpus {
        #expect(DiscourseFillers.apply(testCase.input) == testCase.input,
                "\(testCase.note)")
    }
}
