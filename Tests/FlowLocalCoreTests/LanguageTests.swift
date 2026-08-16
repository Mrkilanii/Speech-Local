import Testing
@testable import FlowLocalCore

private let arabic = RulesCleanup(language: .arabic)
private let unknown = RulesCleanup(language: .other)

// MARK: - Identification

@Test(arguments: [
    ("en-US", Language.english), ("en_GB", .english),
    ("ar-SA", .arabic), ("ar", .arabic), ("ar_EG", .arabic),
    ("fr-FR", .other), ("de-DE", .other), ("", .other),
])
func identifiesLanguageFromLocale(identifier: String, expected: Language) {
    #expect(Language(localeIdentifier: identifier) == expected)
}

// MARK: - Case

@Test func arabicHasNoLetterCase() {
    // Arabic script is unicameral. Capitalisation rules are meaningless, and
    // running them would be a no-op at best.
    #expect(!Language.arabic.hasLetterCase)
    #expect(Language.english.hasLetterCase)
}

@Test func arabicTextIsNotCapitalised() {
    let input = "مرحبا كيف حالك"
    let out = arabic.apply(to: input)
    #expect(out.contains("مرحبا"))
    #expect(!out.isEmpty)
}

@Test func englishStillCapitalises() {
    #expect(RulesCleanup(language: .english).apply(to: "hello there") == "Hello there.")
}

// MARK: - Punctuation

@Test func arabicUsesItsOwnComma() {
    #expect(Language.arabic.comma == "،")
    #expect(Language.english.comma == ",")
}

@Test func arabicAcceptsItsQuestionMarkAsTerminal() {
    // U+061F. Text already ending in it must not gain a stray full stop.
    let out = arabic.apply(to: "كيف حالك؟")
    #expect(out.hasSuffix("؟"), "got: \(out)")
}

@Test func arabicGainsATerminatorWhenMissing() {
    #expect(arabic.apply(to: "مرحبا بك").hasSuffix("."))
}

// MARK: - Fillers

@Test func arabicFillersAreRemoved() {
    let out = arabic.apply(to: "اه مرحبا بك")
    #expect(!out.contains("اه "), "hesitation sound should go: \(out)")
    #expect(out.contains("مرحبا"))
}

@Test func arabicKeepsMeaningfulDiscourseWords() {
    // "يعني" is as common as the English "like" and carries meaning, so it is
    // deliberately not treated as filler.
    let out = arabic.apply(to: "يعني هذا جيد")
    #expect(out.contains("يعني"))
}

@Test func englishFillersDoNotApplyToArabic() {
    // "um" is a real token in no language here, but the point is that the
    // English list must not be consulted for Arabic.
    #expect(!Language.arabic.fillers.contains("um"))
    #expect(Language.english.fillers.contains("um"))
}

// MARK: - Contractions

@Test func contractionRepairIsEnglishOnly() {
    #expect(Language.english.hasContractions)
    #expect(!Language.arabic.hasContractions)
    #expect(!Language.other.hasContractions)
}

@Test func arabicTextIsNotRunThroughContractionTable() {
    let input = "هذا صحيح"
    #expect(!arabic.apply(to: input).contains("'"))
}

// MARK: - Unsupported languages degrade safely

@Test func unknownLanguageAppliesNoFillerRules() {
    #expect(Language.other.fillers.isEmpty)
}

@Test func unknownLanguagePreservesEveryWord() {
    // The contract for an unsupported language: transcribe, tidy whitespace,
    // change nothing else. Silently mangling text is worse than not helping.
    let input = "bonjour comment allez vous aujourd hui"
    let out = unknown.apply(to: input).lowercased()
    for word in input.split(separator: " ") {
        #expect(out.contains(word), "dropped '\(word)'")
    }
}

@Test func unknownLanguageStillCollapsesDuplicates() {
    // Language-neutral tidying is safe everywhere.
    #expect(unknown.apply(to: "le le chat").lowercased().hasPrefix("le chat"))
}

@Test func arabicPreservesEveryContentWord() {
    let input = "نحن نريد أن نبدأ العمل غدا"
    let out = arabic.apply(to: input)
    for word in input.split(separator: " ") {
        #expect(out.contains(word), "dropped '\(word)'")
    }
}

@Test func sparsePolicyIsInertWithoutClauseMarkers() {
    // French has no marker list here, so sparse must fall back to keeping the
    // recognizer's commas rather than stripping all of them.
    let french = RulesCleanup(commaPolicy: .sparse, language: .other)
    let out = french.apply(to: "je pense, donc je suis")
    #expect(out.contains(","), "every comma was stripped: \(out)")
}

@Test func sparsePolicyStillWorksForArabic() {
    // Arabic has markers, so the policy remains active there.
    #expect(!Language.arabic.clauseMarkers.isEmpty)
}

@Test func unknownLanguageKeepsRecognizerPunctuation() {
    let german = RulesCleanup(commaPolicy: .sparse, language: .other)
    let input = "ich denke, dass es gut ist"
    #expect(german.apply(to: input).contains(","))
}
