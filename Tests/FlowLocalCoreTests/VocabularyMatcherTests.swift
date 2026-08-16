import Testing
@testable import FlowLocalCore

// Swift Testing, not XCTest: XCTest ships only with Xcode, and this project
// builds against Command Line Tools. `import XCTest` fails with "no such module".

private let matcher = VocabularyMatcher()

// MARK: - Basic substitution

@Test func singleWordSubstitution() {
    let vocab = Vocabulary(aliases: ["kubernetes": "Kubernetes"])
    #expect(matcher.apply(vocab, to: "we should use kubernetes for this")
            == "we should use Kubernetes for this")
}

@Test func multiWordPhraseSubstitution() {
    // The real case: ASR splits an unusual name into ordinary words.
    let vocab = Vocabulary(aliases: ["kill annie": "Kilanii"])
    #expect(matcher.apply(vocab, to: "ask kill annie about it") == "ask Kilanii about it")
}

@Test func longestPhraseWins() {
    let vocab = Vocabulary(aliases: ["new york": "NYC", "new york city": "New York City"])
    #expect(matcher.apply(vocab, to: "flying to new york city tomorrow")
            == "flying to New York City tomorrow")
}

@Test func caseInsensitiveMatching() {
    let vocab = Vocabulary(aliases: ["swift": "Swift"])
    #expect(matcher.apply(vocab, to: "SWIFT and Swift and swift") == "Swift and Swift and Swift")
}

// MARK: - Whole-token discipline

@Test func doesNotMatchInsideWords() {
    // The classic failure: substring matching damages unrelated words.
    let vocab = Vocabulary(aliases: ["cat": "CAT"])
    #expect(matcher.apply(vocab, to: "concatenate the catalog") == "concatenate the catalog")
}

@Test(arguments: ["new. york", "new, york"])
func phraseNotMatchedAcrossPunctuation(input: String) {
    let vocab = Vocabulary(aliases: ["new york": "NYC"])
    #expect(matcher.apply(vocab, to: input) == input)
}

// MARK: - Protected tokens

@Test func protectsNumbers() {
    let vocab = Vocabulary(aliases: ["v2": "version two"])
    #expect(matcher.apply(vocab, to: "deploy v2 today") == "deploy v2 today")
}

@Test func protectsURLs() {
    let vocab = Vocabulary(aliases: ["example": "EXAMPLE"])
    let input = "see https://example.com/docs for details"
    #expect(matcher.apply(vocab, to: input) == input)
}

@Test func protectsEmails() {
    let vocab = Vocabulary(aliases: ["someone": "Someone"])
    let input = "email someone@example.com now"
    #expect(matcher.apply(vocab, to: input) == input)
}

@Test func protectsFilePaths() {
    let vocab = Vocabulary(aliases: ["users": "USERS"])
    let input = "open /Users/docs/file.txt please"
    #expect(matcher.apply(vocab, to: input) == input)
}

@Test func protectsIdentifiers() {
    // Interior capitals imply code: camelCase, APIKey, iPhone.
    let vocab = Vocabulary(aliases: ["apikey": "API key"])
    #expect(matcher.apply(vocab, to: "set the APIKey now") == "set the APIKey now")
}

// MARK: - Losslessness

@Test func emptyVocabularyIsIdentity() {
    let text = "Hello, world! Visit https://x.com — it's 100% fine.\nNew line."
    #expect(matcher.apply(.empty, to: text) == text)
}

@Test func preservesPunctuationAndWhitespace() {
    let vocab = Vocabulary(aliases: ["swift": "Swift"])
    #expect(matcher.apply(vocab, to: "  swift, swift.  swift!\n\tswift")
            == "  Swift, Swift.  Swift!\n\tSwift")
}

@Test func noAliasLeavesTextUntouched() {
    let vocab = Vocabulary(aliases: ["nothing": "NOTHING"])
    let text = "the quick brown fox jumps over the lazy dog"
    #expect(matcher.apply(vocab, to: text) == text)
}

// MARK: - Vocabulary hygiene

@Test func blankKeysIgnored() {
    let vocab = Vocabulary(aliases: ["": "X", "   ": "Y", "ok": "OK"])
    #expect(vocab.aliases.count == 1)
    #expect(matcher.apply(vocab, to: "ok then") == "OK then")
}

@Test func keysNormalizedToLowercase() {
    let vocab = Vocabulary(aliases: ["  KuBerNetes  ": "Kubernetes"])
    #expect(matcher.apply(vocab, to: "use kubernetes") == "use Kubernetes")
}

// MARK: - Mode invariants

@Test func onlyLightTouchStreams() {
    // Full rewrite may reorder material, so it can never stream into another
    // app's document — committed text cannot be taken back.
    #expect(CleanupMode.lightTouch.supportsStreaming)
    #expect(!CleanupMode.fullRewrite.supportsStreaming)
}
