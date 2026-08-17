import Testing
@testable import SpeechLocalCore

private let rules = RulesCleanup()

// MARK: - Numbering a dictated list

@Test func numbersBecomeListMarkers() {
    #expect(rules.apply(to: "one, do this, two, do that") == "1) do this 2) do that.")
    #expect(rules.apply(to: "one, do this, two, do that, three, and then this")
            == "1) do this 2) do that 3) and then this.")
}

@Test func aSpokenBracketNumbersItExplicitly() {
    // The reliable route, needing no inference at all.
    #expect(rules.apply(to: "one bracket do this two bracket do that")
            == "1) do this 2) do that.")
}

// MARK: - Runs of numbers that are not lists

@Test func quantitiesAreNotAList() {
    // No pause after the number, so no comma, so no list.
    #expect(rules.apply(to: "i need 1 apple and 2 oranges")
            == "I need 1 apple and 2 oranges.")
}

@Test func aNumberThatDoesNotOpenAClauseIsNotAMarker() {
    #expect(rules.apply(to: "chapter 1, the beginning, chapter 2, the end")
            == "Chapter 1 the beginning chapter 2 the end.")
}

@Test func numbersThatDoNotStartAtOneAreNotAList() {
    #expect(rules.apply(to: "in 2020, we shipped, in 2021, we grew")
            == "In 2020 we shipped in 2021 we grew.")
    #expect(rules.apply(to: "two, do this, three, do that")
            == "2 do this 3 do that.")
}

@Test func oneItemIsNotAList() {
    #expect(rules.apply(to: "one, do this") == "1 do this.")
}

@Test func aBrokenSequenceIsNotAList() {
    #expect(rules.apply(to: "one, do this, three, do that")
            == "1 do this 3 do that.")
}

// MARK: - "bracket"

@Test func bracketWritesAClosingParen() {
    #expect(rules.apply(to: "that is it bracket then more")
            == "That is it) then more.")
}

@Test func aBracketWithADeterminerStaysAWord() {
    #expect(rules.apply(to: "add a bracket here") == "Add a bracket here.")
}

@Test func aPluralisedCommandStillCounts() {
    // The recognizer applies grammar to what it hears: "two close bracket"
    // comes back as "Two close brackets." Nothing can be dictated after a
    // number without reading the plural.
    #expect(rules.apply(to: "Two close brackets.") == "2)")
    #expect(rules.apply(to: "Two brackets.") == "2)")
    #expect(rules.apply(to: "is it working question marks") == "Is it working?")
}

@Test func aPluralNeverMakesAWordVanish() {
    // "space" writes nothing, so a plural of it is always the noun — losing a
    // word is the one outcome the speaker cannot see to undo.
    #expect(rules.apply(to: "there are two spaces here") == "There are 2 spaces here.")
    #expect(rules.apply(to: "the slashes are wrong") == "The slashes are wrong.")
}

@Test func bracketsAreParensNotSquareOnes() {
    #expect(rules.apply(to: "open bracket like this close bracket") == "(like this).")
    #expect(rules.apply(to: "open square bracket a close square bracket") == "[a].")
}

@Test func aMarkerDictatedAloneNeedsNoFullStop() {
    #expect(rules.apply(to: "two bracket") == "2)")
}

// MARK: - "one" as a pronoun after an adjective

@Test(arguments: ["important", "good", "last", "next", "big", "same", "right"])
func adjectivesMakeOneAPronoun(adjective: String) {
    let out = rules.apply(to: "it is just the \(adjective) one")
    #expect(out == "It is just the \(adjective) one.")
}

@Test func aCountedNounStillBecomesADigit() {
    #expect(rules.apply(to: "chapter one is done") == "Chapter 1 is done.")
    #expect(rules.apply(to: "i want one coffee") == "I want 1 coffee.")
}
