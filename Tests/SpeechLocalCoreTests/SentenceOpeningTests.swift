import Testing
@testable import SpeechLocalCore

private func adjust(_ text: String, after preceding: String?, raw: String = "") -> String {
    SentenceOpening.adjust(text, following: preceding, raw: raw)
}

// MARK: - When the capital is wrong

@Test func lowercasesWhenTheSentenceIsAlreadyUnderWay() {
    #expect(adjust("We should ship it.", after: "I think ") == "we should ship it.")
    #expect(adjust("Ship it.", after: "so please ") == "ship it.")
}

@Test func lowercasesAfterACommaOrColon() {
    #expect(adjust("Then tell them.", after: "first do it, ") == "then tell them.")
    #expect(adjust("The build is red.", after: "status: ") == "the build is red.")
}

@Test func lowercasesWithNoSpaceBeforeTheCaret() {
    #expect(adjust("World.", after: "hello ") == "world.")
}

// MARK: - When the capital is right

@Test func keepsCapitalAtTheStartOfAnEmptyField() {
    #expect(adjust("Ship it.", after: "") == "Ship it.")
    #expect(adjust("Ship it.", after: "   ") == "Ship it.")
}

@Test func keepsCapitalAfterAFinishedSentence() {
    #expect(adjust("Ship it.", after: "We are done. ") == "Ship it.")
    #expect(adjust("Ship it.", after: "Really! ") == "Ship it.")
    #expect(adjust("Ship it.", after: "Why? ") == "Ship it.")
}

@Test func keepsCapitalOnANewLine() {
    #expect(adjust("Ship it.", after: "the plan\n") == "Ship it.")
    #expect(adjust("Ship it.", after: "the plan\n\n  ") == "Ship it.")
}

@Test func keepsCapitalWhenTheAppExposesNothing() {
    // Terminals and most Electron apps publish no value; the old behaviour
    // stands rather than guessing.
    #expect(adjust("Ship it.", after: nil) == "Ship it.")
}

// MARK: - Capitals that are not about sentence position

@Test func keepsStandaloneI() {
    #expect(adjust("I think so.", after: "he said ") == "I think so.")
}

@Test func keepsAcronymsAndInternalCapitals() {
    #expect(adjust("RAG is the approach.", after: "we use ") == "RAG is the approach.")
    #expect(adjust("iPhone only.", after: "it is ") == "iPhone only.")
}

@Test func keepsDaysAndMonths() {
    #expect(adjust("Monday works.", after: "i think ") == "Monday works.")
    #expect(adjust("March is fine.", after: "i think ") == "March is fine.")
}

@Test func keepsAProperNounTheRecognizerCapitalized() {
    // "Omar" is capitalized again later in the raw transcript, so its capital
    // is the recognizer's judgement rather than sentence position.
    #expect(adjust("Omar will know.", after: "ask ", raw: "omar will know ask Omar")
            == "Omar will know.")
}

@Test func lowercasesAWordCapitalizedOnlyAsTheFirstWord() {
    // The recognizer capitalizes its own opening word, so that one occurrence
    // proves nothing.
    #expect(adjust("So we ship.", after: "i think ", raw: "So we ship") == "so we ship.")
}

// MARK: - Openings inside a line

@Test func keepsCapitalAfterAnOpeningBracket() {
    #expect(adjust("Ship it.", after: "the plan (") == "Ship it.")
    #expect(adjust("Ship it.", after: "- [") == "Ship it.")
    #expect(adjust("Ship it.", after: "he said \"") == "Ship it.")
}

@Test func keepsCapitalAfterAListMarker() {
    for marker in ["- ", "* ", "+ ", "• ", "1. ", "2) ", "a. ", "b) ",
                   "(1) ", "> ", "## ", "- [ ] ", "* [x] ", "  - "] {
        #expect(adjust("Ship it.", after: marker) == "Ship it.",
                "marker \"\(marker)\" should open an item")
    }
}

@Test func keepsCapitalAfterAMarkerOnAContinuingLine() {
    #expect(adjust("Ship it.", after: "the plan\n- ") == "Ship it.")
    #expect(adjust("Ship it.", after: "first thing\n2. ") == "Ship it.")
}

@Test func stillLowercasesAfterRealWordsOnAListLine() {
    // The marker rule fires only while the item is still empty.
    #expect(adjust("Ship it.", after: "- we should ") == "ship it.")
    #expect(adjust("Ship it.", after: "1. tell them and ") == "ship it.")
}

@Test func aTypedWordIsNotAListMarker() {
    #expect(adjust("Think so.", after: "I ") == "think so.")
    #expect(adjust("Ship it.", after: "hello ") == "ship it.")
}
