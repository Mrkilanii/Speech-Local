import Foundation

/// Deterministic light-touch cleanup. No model, no network, no variance.
///
/// Chosen over the LLM after measurement: `FoundationModels` on this hardware
/// ran a median of 7.2 s for novel input (0/10 within the 1.5 s budget) and, in
/// 2 of 10 corpus items, silently truncated or emptied the output with no error
/// raised. For a mode whose contract is "fix punctuation, change nothing else",
/// losing the user's words is a correctness failure — and an unpredictable
/// 1–8 s wait defeats the point of dictation.
///
/// The deliberate limitation: this **cannot resolve self-corrections**
/// ("Monday, no actually Tuesday"). Neither could the model, even given an
/// explicit rule and a worked example, so nothing was given up by choosing rules.
public struct RulesCleanup: Sendable {
    /// Removed unconditionally. Kept deliberately short: these are sounds, not
    /// words. Context-dependent candidates ("like", "so", "right", "you know")
    /// are **not** included — they frequently carry meaning, and deleting them
    /// is exactly the content loss this path exists to avoid.
    static let fillers: Set<String> = ["um", "uh", "erm", "uhh", "umm", "hmm", "mm", "mmm"]

    /// Words that legitimately repeat and must survive de-duplication.
    static let legitimateRepeats: Set<String> = ["had", "that", "very", "no", "so"]

    /// Always-capitalized words. Deliberately limited to closed sets — days and
    /// months — where there is no ambiguity. General proper nouns need the
    /// user's vocabulary, not guesswork.
    static let alwaysCapitalized: [String: String] = {
        let words = ["monday", "tuesday", "wednesday", "thursday", "friday",
                     "saturday", "sunday", "january", "february", "march",
                     "april", "may", "june", "july", "august", "september",
                     "october", "november", "december"]
        return Dictionary(uniqueKeysWithValues: words.map { ($0, $0.capitalized) })
    }()

    public init() {}

    public func apply(to transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var tokens = tokenize(trimmed)
        tokens = removeFillers(tokens)
        tokens = collapseRepeats(tokens)
        guard !tokens.isEmpty else { return "" }

        tokens = capitalizeKnownWords(tokens)
        var text = reassemble(tokens)
        text = capitalizeSentences(text)
        text = fixStandaloneI(text)
        text = ensureTerminalPunctuation(text)
        return text
    }

    // MARK: - Steps

    private func removeFillers(_ tokens: [String]) -> [String] {
        tokens.filter { token in
            let bare = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            return !Self.fillers.contains(bare)
        }
    }

    /// Collapses an immediately repeated word ("the the" → "the"). Only exact,
    /// adjacent duplicates, and never for words that legitimately double.
    private func collapseRepeats(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for token in tokens {
            let bare = token.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let last = out.last?.lowercased().trimmingCharacters(in: .punctuationCharacters),
               last == bare, !bare.isEmpty, !Self.legitimateRepeats.contains(bare) {
                continue
            }
            out.append(token)
        }
        return out
    }

    /// Capitalizes the first letter of the text and of anything following a
    /// sentence terminator. Does **not** invent sentence boundaries — inferring
    /// them needs semantics, and guessing wrong is worse than leaving a run-on.
    private func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for ch in text {
            if capitalizeNext, ch.isLetter {
                result.append(Character(ch.uppercased()))
                capitalizeNext = false
            } else {
                result.append(ch)
                if ch == "." || ch == "!" || ch == "?" { capitalizeNext = true }
            }
        }
        return result
    }

    /// Standalone "i" → "I". Safe: no English word is a bare lowercase "i".
    private func fixStandaloneI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\bi\\b", with: "I", options: [.regularExpression])
    }

    private func ensureTerminalPunctuation(_ text: String) -> String {
        guard let last = text.last else { return text }
        if last == "." || last == "!" || last == "?" { return text }
        if last == "," || last == ";" || last == ":" {
            return String(text.dropLast()) + "."
        }
        return text + "."
    }

    /// Capitalizes days and months, preserving any attached punctuation.
    private func capitalizeKnownWords(_ tokens: [String]) -> [String] {
        tokens.map { token in
            let bare = token.trimmingCharacters(in: .punctuationCharacters)
            guard let fixed = Self.alwaysCapitalized[bare.lowercased()] else { return token }
            return token.replacingOccurrences(of: bare, with: fixed)
        }
    }

    // MARK: - Tokenizing

    private func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    private func reassemble(_ tokens: [String]) -> String {
        tokens.joined(separator: " ")
    }
}
