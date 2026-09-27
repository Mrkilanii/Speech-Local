import Testing
@testable import SpeechLocalCore

// MARK: - Acceptance table (architect-2, Phase 5)

@Test(arguments: [
    ("Tell him it's late, scratch that, tell him it's ready.", "tell him it's ready."),
    ("Buy milk. Tell him it's late. Scratch that. Tell him it's ready.", "Buy milk. Tell him it's ready."),
    ("Scratch that, hello there.", "hello there."),
    ("Buy milk. Call mom scratch that", "Buy milk."),
    ("A. B. Scratch that. Scratch that. C.", "C."),
    ("Call mom, scratch that.", ""),
    ("Please don't scratch that.", "Please don't scratch that."),
    ("Scratch that surface gently", "Scratch that surface gently"),
])
func scratchThatAcceptance(input: String, expected: String) {
    #expect(ScratchThat.apply(input) == expected)
}

// MARK: - Matching ignores case

@Test func scratchThatMatchesInAnyCase() {
    #expect(ScratchThat.apply("Call mom, SCRATCH THAT, call dad.") == "call dad.")
    #expect(ScratchThat.apply("Call mom, Scratch That, call dad.") == "call dad.")
}

@Test func scratchThatNegationGuardComparesTheBareLowercasedWord() {
    // Punctuation and case on the word before must not defeat the guard.
    #expect(ScratchThat.apply("DON'T scratch that.") == "DON'T scratch that.")
    #expect(ScratchThat.apply("Never, scratch that.") == "Never, scratch that.")
    #expect(ScratchThat.apply("I want to scratch that.") == "I want to scratch that.")
}

// MARK: - The promise to the rest of light-touch

@Test func scratchThatLeavesEveryCorpusInputUnchanged() {
    for testCase in LightTouchInvariants.corpus {
        #expect(ScratchThat.apply(testCase.input) == testCase.input, "\(testCase.note)")
    }
}

@Test func scratchThatKeepsWhitespaceWhenNothingFires() {
    let text = "first line\nsecond  line"
    #expect(ScratchThat.apply(text) == text)
}
