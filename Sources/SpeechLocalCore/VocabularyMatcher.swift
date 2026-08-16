import Foundation

/// User-supplied substitutions applied after transcription.
///
/// Keys are what the transcriber tends to *hear*; values are what should be
/// written. Multi-word keys are supported because ASR commonly splits an unusual
/// name into ordinary words ("kill annie" → "Kilanii").
public struct Vocabulary: Sendable, Equatable {
    /// Lowercased spoken form → replacement, exactly as the user typed it.
    public let aliases: [String: String]

    public static let empty = Vocabulary(aliases: [:])

    public init(aliases: [String: String]) {
        var normalized: [String: String] = [:]
        for (spoken, written) in aliases {
            let key = spoken.lowercased().trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            normalized[key] = written
        }
        self.aliases = normalized
    }

    /// Longest key length in words. Bounds the phrase-matching window.
    var maxPhraseLength: Int {
        aliases.keys.map { $0.split(separator: " ").count }.max() ?? 0
    }
}

/// Applies a `Vocabulary` to transcribed text.
///
/// Two rules keep this from mangling text, both learned the hard way in similar
/// tools:
///
/// 1. **Whole tokens only.** Substring matching turns an alias for "cat" into
///    damage inside "concatenate".
/// 2. **Protected tokens are never touched.** Numbers, URLs, emails, file paths,
///    and code-ish tokens pass through untouched, because a dictation tool that
///    rewrites part of a URL is worse than one that misspells a name.
public struct VocabularyMatcher: Sendable {
    public init() {}

    public func apply(_ vocabulary: Vocabulary, to text: String) -> String {
        guard !vocabulary.aliases.isEmpty, !text.isEmpty else { return text }

        let tokens = Self.tokenize(text)
        let maxPhrase = max(1, vocabulary.maxPhraseLength)
        var out = ""
        var i = 0

        while i < tokens.count {
            let token = tokens[i]

            guard case .word(let raw) = token.kind, !Self.isProtected(raw) else {
                out += token.text
                i += 1
                continue
            }

            // Longest match first, so "new york city" wins over "new york".
            var matched = false
            var length = min(maxPhrase, tokens.count - i)

            while length >= 1 && !matched {
                let slice = Array(tokens[i..<(i + length)])
                // A phrase must be words separated only by single spaces;
                // punctuation inside a candidate phrase disqualifies it.
                if Self.isContiguousWordRun(slice) {
                    let phrase = slice.compactMap { token -> String? in
                        if case .word(let w) = token.kind { return w.lowercased() }
                        return nil
                    }.joined(separator: " ")

                    if let replacement = vocabulary.aliases[phrase] {
                        out += replacement
                        // Preserve trailing separator of the final token.
                        out += slice[slice.count - 1].trailing
                        i += length
                        matched = true
                        break
                    }
                }
                length -= 1
            }

            if !matched {
                out += token.text
                i += 1
            }
        }

        return out
    }

    // MARK: - Protection

    /// Tokens that must never be rewritten.
    static func isProtected(_ word: String) -> Bool {
        if word.contains(where: \.isNumber) { return true }
        let lower = word.lowercased()
        if lower.contains("://") || lower.hasPrefix("www.") || word.contains("@") { return true }
        if word.contains("/") || word.contains("\\") || word.contains("_") { return true }
        // Mixed case with a capital past position 0 implies an identifier:
        // camelCase, APIKey, iPhone. Requiring *both* cases matters — otherwise
        // an all-caps word ("SWIFT", someone shouting) is mistaken for code.
        let hasUpper = word.contains(where: \.isUppercase)
        let hasLower = word.contains(where: \.isLowercase)
        if hasUpper, hasLower, word.dropFirst().contains(where: \.isUppercase) { return true }
        return false
    }

    // MARK: - Tokenizing

    enum Kind: Equatable {
        case word(String)
        case other
    }

    struct Token {
        let kind: Kind
        /// The token plus whatever separator followed it, so reassembly is lossless.
        let text: String
        let trailing: String
    }

    /// Splits into word tokens carrying their trailing separators, so joining
    /// the `text` values reproduces the input byte for byte.
    static func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var separator = ""
        var inWord = false

        func flush() {
            guard inWord else { return }
            tokens.append(Token(kind: .word(current), text: current + separator, trailing: separator))
            current = ""
            separator = ""
            inWord = false
        }

        let chars = Array(text)
        for (index, ch) in chars.enumerated() {
            // `.` and `:` are word characters only *between* alphanumerics, so
            // "example.com" stays one token while a sentence-ending "swift."
            // does not swallow its period — that would break alias lookup.
            var joinsWords = false
            if ch == "." || ch == ":" {
                let prevOK = index > 0 && (chars[index - 1].isLetter || chars[index - 1].isNumber)
                let nextOK = index + 1 < chars.count
                    && (chars[index + 1].isLetter || chars[index + 1].isNumber)
                joinsWords = prevOK && nextOK
            }

            let isWordChar = ch.isLetter || ch.isNumber || ch == "'" || ch == "’"
                || ch == "_" || ch == "/" || ch == "\\" || ch == "@" || joinsWords
            if isWordChar {
                if !separator.isEmpty {
                    // Separator then a new word: close the previous token first.
                    flush()
                }
                current.append(ch)
                inWord = true
            } else if inWord {
                separator.append(ch)
            } else {
                tokens.append(Token(kind: .other, text: String(ch), trailing: ""))
            }
        }
        flush()
        return tokens
    }

    /// True when every token is a word and the separators between them are
    /// exactly one space (no punctuation, no line breaks).
    static func isContiguousWordRun(_ tokens: [Token]) -> Bool {
        guard !tokens.isEmpty else { return false }
        for (index, token) in tokens.enumerated() {
            guard case .word = token.kind else { return false }
            if index < tokens.count - 1 && token.trailing != " " { return false }
        }
        return true
    }
}
