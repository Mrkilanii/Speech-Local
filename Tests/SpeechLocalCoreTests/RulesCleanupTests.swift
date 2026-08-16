import Testing
@testable import SpeechLocalCore

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
    #expect(rules.apply(to: "first thing. another thing") == "First thing. Another thing.")
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
    #expect(rules.apply(to: "first thing. Another thing")
            == "First thing. Another thing.")
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

// MARK: - Stutters

@Test(arguments: [
    ("st stop the build", "Stop the build."),
    ("comp computer is slow", "Computer is slow."),
    ("fri friday works for me", "Friday works for me."),
])
func collapsesStutterOnNonWordFragment(input: String, expected: String) {
    #expect(rules.apply(to: input) == expected)
}

@Test func doesNotCollapseRealWordPrefix() {
    // "to today" is genuinely ambiguous — "go to today's meeting" is ordinary
    // English. Automatic collapse would wreck it, so this is left to the
    // learned-corrections path where the user confirms it in context.
    #expect(rules.apply(to: "go to today's meeting").contains("to today"))
}

@Test func doesNotCollapseUnrelatedAdjacentWords() {
    #expect(rules.apply(to: "the theatre was open") == "The theatre was open.")
}

@Test func doesNotCollapseAcrossPunctuation() {
    // Both words must survive. (The comma itself is separately dropped by the
    // .sparse policy, which is why this asserts words rather than punctuation.)
    let out = rules.apply(to: "stop, stopping now").lowercased()
    #expect(out.contains("stop"))
    #expect(out.contains("stopping"))
    #expect(tidy.apply(to: "stop, stopping now").lowercased().contains("stop,"))
}

// MARK: - Restated sentences

@Test func collapsesImmediatelyRestatedSentence() {
    // The observed case: the speaker stumbled and said the sentence again.
    let input = "But there's also thingsings that can hinder your experience. "
              + "But there's also things that can hinder your experience."
    let out = rules.apply(to: input)
    #expect(!out.contains("thingsings"), "the stumbled version should be dropped")
    #expect(out.contains("things that can hinder your experience"))
}

@Test func keepsDeliberateShortRepetition() {
    // Under five words, so emphasis survives.
    #expect(rules.apply(to: "Stop. Stop.").lowercased().contains("stop. stop"))
}

@Test func keepsGenuinelyDifferentSentences() {
    let input = "We should ship the feature today. The tests are all passing now."
    let out = rules.apply(to: input)
    #expect(out.contains("ship the feature today"))
    #expect(out.contains("tests are all passing"))
}

@Test func keepsSentencesThatMerelyShareCommonWords() {
    // Same function words, different content — must not be treated as a restatement.
    let input = "I think we should go to the office today. "
              + "I think we should call the client tomorrow."
    let out = rules.apply(to: input)
    #expect(out.contains("office"))
    #expect(out.contains("client"))
}

@Test func collapsesOnlyAdjacentPairs() {
    let input = "The build is broken again. We need to fix the tests. The build is broken again."
    let out = rules.apply(to: input)
    // Non-adjacent duplicates are left alone — they may be deliberate.
    #expect(out.contains("need to fix the tests"))
}

@Test func similarityIsSymmetricAndBounded() {
    let a = "we should ship it on monday"
    let b = "we should ship it on tuesday"
    #expect(RulesCleanup.similarity(a, b) == RulesCleanup.similarity(b, a))
    #expect(RulesCleanup.similarity(a, a) == 1.0)
    #expect(RulesCleanup.similarity(a, "completely unrelated words here") < 0.3)
}

// MARK: - Contractions

@Test(arguments: [
    ("that wasnt right", "That wasn't right."),
    ("i dont think so", "I don't think so."),
    ("its ok but thats wrong", "Its ok but that's wrong."),
    ("youre going to like it", "You're going to like it."),
    ("we couldnt finish it", "We couldn't finish it."),
    ("theres no time left", "There's no time left."),
])
func restoresApostrophes(input: String, expected: String) {
    #expect(rules.apply(to: input) == expected)
}

@Test func preservesCaseWhenFixingContractions() {
    #expect(rules.apply(to: "Dont do that") == "Don't do that.")
}

@Test func keepsPunctuationAroundContractions() {
    // The terminal "!" must survive the apostrophe fix. (The comma is separately
    // dropped by the .sparse policy, so this pins .tidy to test one thing.)
    #expect(rules.apply(to: "wait, dont!") == "Wait don't!")
    #expect(tidy.apply(to: "wait, dont!") == "Wait, don't!")
}

@Test(arguments: ["were", "well", "hell", "shed", "wont", "cant", "id"])
func leavesAmbiguousWordsAlone(word: String) {
    // Each of these is a real word as well as a contraction. Rewriting them
    // would corrupt correct text, so they are deliberately excluded.
    let out = rules.apply(to: "the \(word) is here").lowercased()
    #expect(out.contains(word))
    #expect(!out.contains("'"), "'\(word)' must not gain an apostrophe")
}

@Test func leavesItsAlone() {
    // "its" and "it's" are distinguished only by grammar, which rules cannot do.
    #expect(rules.apply(to: "its color is red") == "Its color is red.")
}

@Test func doesNotTouchAlreadyCorrectContractions() {
    #expect(rules.apply(to: "that wasn't right") == "That wasn't right.")
}

// MARK: - Numbers

@Test func writesSpokenNumbersAsDigits() {
    #expect(rules.apply(to: "send me one file") == "Send me 1 file.")
    #expect(rules.apply(to: "i need seven copies") == "I need 7 copies.")
}

@Test func writesCompoundNumbersAsDigits() {
    #expect(rules.apply(to: "it took twenty three minutes") == "It took 23 minutes.")
    #expect(rules.apply(to: "twenty-three minutes") == "23 minutes.")
    #expect(rules.apply(to: "about two thousand five hundred") == "About 2500.")
    #expect(rules.apply(to: "one hundred and five") == "100 and 5.")
}

@Test func capitalizesCorrectlyAfterALeadingDigit() {
    // The sentence opens on a digit, so the following word must stay lowercase.
    #expect(rules.apply(to: "three things went wrong") == "3 things went wrong.")
}

@Test func readsAdjacentDigitsAsOneFigure() {
    // How a code, extension or account number is actually dictated.
    #expect(rules.apply(to: "the code is five five five") == "The code is 555.")
    #expect(rules.apply(to: "account four four seven two") == "Account 4472.")
    #expect(rules.apply(to: "it is three four") == "It is 34.")
}

@Test func readsOhAsZeroInsideAFigure() {
    #expect(rules.apply(to: "room one oh five") == "Room 105.")
    #expect(rules.apply(to: "room one zero five") == "Room 105.")
    // Leading zeros survive, so a dialling code is not silently shortened.
    #expect(rules.apply(to: "call me on oh two one") == "Call me on 021.")
}

@Test func leavesOhAloneWhenItIsNotADigit() {
    #expect(rules.apply(to: "meet me at five o clock") == "Meet me at 5 o clock.")
    #expect(rules.apply(to: "oh two years ago") == "Oh 2 years ago.")
}

@Test func spokenSeparatorsBreakAFigure() {
    #expect(rules.apply(to: "three comma four") == "3, 4.")
    #expect(rules.apply(to: "three space four") == "3 4.")
    // Already punctuated by the recognizer, same result.
    #expect(tidy.apply(to: "three, four and five") == "3, 4 and 5.")
    // Only between two digits — elsewhere they are ordinary words.
    #expect(rules.apply(to: "we are out of disk space") == "We are out of disk space.")
    #expect(rules.apply(to: "the comma is missing") == "The comma is missing.")
}

@Test func scaleWordsStayArithmetic() {
    // "five hundred" is 500, not a digit run.
    #expect(rules.apply(to: "five hundred and six") == "500 and 6.")
    #expect(rules.apply(to: "two thousand twenty five") == "2025.")
}

@Test func keepsPunctuationAroundNumbers() {
    #expect(tidy.apply(to: "there were twelve, then more")
            == "There were 12, then more.")
}

@Test func spellingANumberWritesTheWord() {
    #expect(rules.apply(to: "just o n e more") == "Just one more.")
    #expect(rules.apply(to: "just O-N-E more") == "Just one more.")
    #expect(rules.apply(to: "s i x t y percent") == "Sixty percent.")
}

@Test func spelledLettersThatAreNotNumbersAreLeftAlone() {
    // Joining every letter run would turn "F B I" into "fbi".
    #expect(rules.apply(to: "he works at F B I now").contains("F B I"))
}

@Test func leavesPronounOneAlone() {
    #expect(rules.apply(to: "that is one of them") == "That is one of them.")
    #expect(rules.apply(to: "no one came") == "No one came.")
    #expect(rules.apply(to: "the one i meant") == "The one I meant.")
    #expect(rules.apply(to: "give me this one") == "Give me this one.")
    #expect(rules.apply(to: "just one more") == "Just one more.")
    #expect(rules.apply(to: "one thing at a time") == "One thing at a time.")
}

@Test func leavesTwoAloneWhereItIsAMisheardTo() {
    // The recognizer writes "two" for "to"; committing to "2 the" makes it
    // worse, so the word stands.
    #expect(rules.apply(to: "send it two the team") == "Send it two the team.")
    #expect(rules.apply(to: "i need two go") == "I need two go.")
}

@Test func stillConvertsAmbiguousWordsOutsideTheirFrames() {
    #expect(rules.apply(to: "i have two apples") == "I have 2 apples.")
    #expect(rules.apply(to: "chapter one is done") == "Chapter 1 is done.")
    // Punctuation separates the frame, so the exception does not apply.
    #expect(tidy.apply(to: "i have two, the rest are gone")
            == "I have 2, the rest are gone.")
}

@Test func leavesNumbersAloneInUnsupportedLanguages() {
    let other = RulesCleanup(language: .other)
    #expect(other.apply(to: "send me one file") == "Send me one file.")
}
