import Testing
@testable import SpeechLocalCore

// MARK: - Acceptance table (architect-2, Phase 6)

@Test(arguments: [
    ("let's do coffee at 2 actually 3", "let's do coffee at 3"),
    ("Let's meet Monday, no actually Tuesday.", "Let's meet Tuesday."),
    ("116, no, 125. 125 does work.", "125. 125 does work."),
    ("24, I mean, 8 divided by Y", "8 divided by Y"),
    ("at 3:30, sorry, 4:15 today", "at 4:15 today"),
    ("(2 actually 3)", "(3)"),
    ("1 actually 2 actually 3", "3"),
    ("I actually enjoyed the movie", "I actually enjoyed the movie"),
    ("Monday actually 3", "Monday actually 3"),
    ("It was 2. Actually 3 people came.", "It was 2. Actually 3 people came."),
    ("at 2 pm actually 3 pm", "at 2 pm actually 3 pm"),
    ("at two actually three", "at two actually three"),
    ("at 1,000 actually 2,000", "at 1,000 actually 2,000"),
])
func correctedValueAcceptance(input: String, expected: String) {
    #expect(CorrectedValue.apply(input) == expected)
}

// MARK: - Matching ignores case

@Test func correctedValueConnectorsMatchInAnyCase() {
    #expect(CorrectedValue.apply("at 2, Actually, 3") == "at 3")
    #expect(CorrectedValue.apply("at 2, NO, 3") == "at 3")
    #expect(CorrectedValue.apply("at 2, Sorry 3") == "at 3")
    #expect(CorrectedValue.apply("at 2 Wait 3") == "at 3")
    #expect(CorrectedValue.apply("at 2, i MEAN, 3") == "at 3")
}

@Test func correctedValueNamesMatchInAnyCase() {
    #expect(CorrectedValue.apply("meet monday actually TUESDAY") == "meet TUESDAY")
    #expect(CorrectedValue.apply("due in march, no, april") == "due in april")
    #expect(CorrectedValue.apply("at 3PM actually 4pm") == "at 4pm")
}

// MARK: - "May" is a month only when capitalised

@Test func capitalisedMayIsTheMonth() {
    #expect(CorrectedValue.apply("meet in May, actually June") == "meet in June")
}

@Test func lowercaseMayIsTheVerb() {
    #expect(CorrectedValue.apply("we may, actually, may not") == "we may, actually, may not")
    #expect(CorrectedValue.apply("in june, actually may") == "in june, actually may")
}

// MARK: - The promise to the rest of light-touch

@Test func correctedValueLeavesEveryCorpusInputUnchanged() {
    for testCase in LightTouchInvariants.corpus {
        #expect(CorrectedValue.apply(testCase.input) == testCase.input, "\(testCase.note)")
    }
}

@Test func correctedValueKeepsWhitespaceWhenNothingFires() {
    let text = "at 2\nthen  3"
    #expect(CorrectedValue.apply(text) == text)
}
