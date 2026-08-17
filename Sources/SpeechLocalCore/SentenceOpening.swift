import Foundation

/// Decides whether dictated text should open with a capital, from what is
/// already in the field in front of the caret.
///
/// Cleanup capitalizes the first word because a transcript is a sentence. But
/// the caret is often mid-sentence — half a line typed, then the rest dictated —
/// and the capital lands in the middle of it: "I think We should ship".
///
/// So the target's own text decides. A capital is right at the start of the
/// field, after a full stop, or on a new line; anywhere else the word is
/// lowercased back.
///
/// Four things are never lowercased, because their capital is not about
/// sentence position: "I", a word with more capitals inside it (`RAG`,
/// `iPhone`), a day or month, and a proper noun the recognizer itself
/// capitalized elsewhere in the same transcript.
public enum SentenceOpening {
    public static func adjust(
        _ text: String, following preceding: String?, raw: String
    ) -> String {
        guard let preceding, startsMidSentence(preceding) else { return text }
        guard let first = text.first, first.isUppercase else { return text }

        let word = text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? text
        let bare = word.trimmingCharacters(in: .punctuationCharacters)
        guard !bare.isEmpty, bare != "I",
              !bare.dropFirst().contains(where: \.isUppercase),
              RulesCleanup.alwaysCapitalized[bare.lowercased()] == nil,
              !isProperNoun(bare, in: raw)
        else { return text }

        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// Whether the caret sits inside a sentence already under way.
    private static func startsMidSentence(_ preceding: String) -> Bool {
        // A line break makes a fresh start even though text precedes it.
        let gap = preceding.reversed().prefix(while: \.isWhitespace)
        guard !gap.contains(where: \.isNewline) else { return false }

        let trimmed = preceding.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return false }   // nothing before the caret
        return !".!?".contains(last)
    }

    /// Whether the recognizer capitalized this word somewhere it was not
    /// obliged to. Its own first word is skipped: that capital is sentence
    /// position too, and checking it would defeat the whole rule.
    private static func isProperNoun(_ word: String, in raw: String) -> Bool {
        raw.split(whereSeparator: \.isWhitespace).dropFirst().contains {
            $0.trimmingCharacters(in: .punctuationCharacters) == word
        }
    }
}
