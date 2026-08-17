import Testing
@testable import SpeechLocalCore

private let rules = RulesCleanup()
private let tidy = RulesCleanup(commaPolicy: .tidy)

// MARK: - Words become marks

@Test func sentencePunctuationIsSpoken() {
    #expect(rules.apply(to: "hello comma world") == "Hello, world.")
    #expect(rules.apply(to: "done full stop") == "Done.")
    #expect(rules.apply(to: "done period") == "Done.")
    #expect(rules.apply(to: "is it working question mark") == "Is it working?")
    #expect(rules.apply(to: "wow exclamation mark") == "Wow!")
    #expect(rules.apply(to: "name colon omar") == "Name: omar.")
}

@Test func aSpokenFullStopStartsANewSentence() {
    #expect(rules.apply(to: "ship it full stop tell the team")
            == "Ship it. Tell the team.")
}

@Test func joiningMarksBindBothSides() {
    #expect(rules.apply(to: "and slash or") == "And/or.")
    #expect(rules.apply(to: "the file is read me dot txt")
            == "The file is read me.txt.")
    #expect(rules.apply(to: "user underscore name") == "User_name.")
    #expect(rules.apply(to: "omar at sign example dot com")
            == "Omar@example.com.")
}

@Test func aJoiningDotDoesNotStartASentence() {
    // "me.txt" has a full stop in it and is not two sentences.
    #expect(rules.apply(to: "open read me dot txt now")
            == "Open read me.txt now.")
}

@Test func openingMarksAttachToWhatFollows() {
    #expect(rules.apply(to: "cost is dollar sign fifty") == "Cost is $50.")
    #expect(rules.apply(to: "open paren like this close paren") == "(like this).")
}

@Test func punctuationWorksWithNumbers() {
    #expect(rules.apply(to: "ratio is three slash four") == "Ratio is 3/4.")
    #expect(rules.apply(to: "three comma four") == "3, 4.")
}

// MARK: - Words that stay words

@Test func aDeterminerMakesItANoun() {
    // The pause that told the recognizer is gone by the time the text
    // arrives, so the guard is grammatical: a noun has a determiner.
    #expect(rules.apply(to: "the comma is missing") == "The comma is missing.")
    #expect(rules.apply(to: "add a comma here") == "Add a comma here.")
    #expect(rules.apply(to: "put a question mark there") == "Put a question mark there.")
    #expect(rules.apply(to: "a dash of salt") == "A dash of salt.")
    #expect(rules.apply(to: "the period was long") == "The period was long.")
    #expect(rules.apply(to: "we are out of disk space") == "We are out of disk space.")
}

@Test func punctuationOnTheWordItselfMeansItIsAWord() {
    // "leave one space, two of them" is a sentence; the comma belongs to the
    // clause, not to a spoken separator.
    #expect(rules.apply(to: "leave one space, two of them")
            == "Leave 1 space, 2 of them.")
}

@Test func theCommaPolicyKeepsEvidenceForTheNextStep() {
    // Sparse runs first and must not strip the comma that distinguishes the
    // two readings — but it still drops an ordinary hesitation comma.
    #expect(rules.apply(to: "i was thinking, that maybe, we should do it")
            == "I was thinking that maybe we should do it.")
}

@Test func aCommandNeedsSomethingToAttachTo() {
    #expect(rules.apply(to: "comma") == "Comma.")
    #expect(rules.apply(to: "slash") == "Slash.")
}

// MARK: - Spelling it out

@Test func spellingAPunctuationWordWritesTheWord() {
    #expect(rules.apply(to: "c o m m a") == "Comma.")
    #expect(rules.apply(to: "s l a s h") == "Slash.")
    #expect(rules.apply(to: "spell it c o m m a please") == "Spell it comma please.")
    #expect(rules.apply(to: "C-O-M-M-A") == "Comma.")
}

@Test func spellingStillWorksForNumbers() {
    #expect(rules.apply(to: "just o n e more") == "Just one more.")
    #expect(rules.apply(to: "s i x t y percent") == "Sixty percent.")
}

@Test func spelledLettersThatSpellNothingKnownAreLeftAlone() {
    #expect(rules.apply(to: "he works at F B I now").contains("F B I"))
}

// MARK: - Unsupported languages

@Test func punctuationWordsAreNotTouchedInOtherLanguages() {
    let other = RulesCleanup(language: .other)
    #expect(other.apply(to: "hello comma world") == "Hello comma world.")
}
