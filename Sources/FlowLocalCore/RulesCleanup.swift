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

    /// How to treat commas the recognizer inserted.
    ///
    /// Apple's `SpeechTranscriber` punctuates from prosody, so a pause becomes a
    /// comma. That is right for natural speech and wrong for someone thinking
    /// mid-sentence, and the two are indistinguishable from the text alone.
    public enum CommaPolicy: Sendable {
        /// Keep the recognizer's commas; fix only mechanically broken ones.
        case tidy
        /// Additionally drop commas that do not precede a clause marker.
        /// Sparser, but never punctuates a hesitation.
        case sparse
    }

    public var commaPolicy: CommaPolicy

    public init(commaPolicy: CommaPolicy = .sparse) {
        self.commaPolicy = commaPolicy
    }

    /// Words that are never proper nouns, so a capital on them mid-utterance is
    /// always an artifact rather than a name. Used to undo the sentence break
    /// Apple's transcriber inserts when the speaker simply pauses to think.
    static let neverProperNouns: Set<String> = [
        "a", "an", "the", "and", "but", "or", "so", "because", "if", "when",
        "while", "that", "this", "these", "those", "it", "its", "we", "you",
        "they", "he", "she", "them", "us", "our", "your", "their", "his", "her",
        "is", "was", "are", "were", "be", "been", "am", "do", "does", "did",
        "have", "has", "had", "will", "would", "should", "could", "can", "may",
        "might", "must", "need", "want", "think", "know", "make", "made",
        "get", "got", "go", "going", "went", "come", "came", "take", "took",
        "see", "saw", "say", "said", "just", "also", "then", "than", "there",
        "here", "very", "really", "actually", "maybe", "probably", "still",
        "about", "with", "from", "into", "over", "under", "after", "before",
        "for", "to", "of", "on", "at", "by", "as", "in", "out", "up", "down",
        "not", "no", "yes", "okay", "well", "like", "some", "any", "all",
        "more", "most", "much", "many", "each", "every", "other", "another",
        "today", "tomorrow", "yesterday", "tonight", "now", "soon", "later",
    ]

    /// Short words that stand on their own. A fragment matching one of these is
    /// assumed to be a real word rather than a stutter.
    static let realWords: Set<String> = neverProperNouns.union([
        "i", "me", "my", "he", "us", "am", "an", "as", "at", "be", "by", "do",
        "go", "if", "in", "is", "it", "no", "of", "on", "or", "so", "to", "up",
        "we", "who", "why", "how", "one", "two", "six", "ten", "new", "old",
        "own", "put", "run", "set", "let", "may", "far", "few", "big", "top",
        "end", "add", "ask", "buy", "try", "use", "way", "yes", "yet", "car",
        "day", "eye", "job", "key", "law", "man", "map", "pay", "war", "win",
    ])

    /// Words that genuinely follow a comma. Used by `.sparse` to keep the commas
    /// that carry grammar and drop the ones that mark a breath.
    static let clauseMarkers: Set<String> = [
        "and", "but", "or", "so", "because", "which", "who", "although",
        "though", "however", "then", "if", "unless", "while", "whereas",
        "please", "too", "right", "okay",
    ]

    public func apply(to transcript: String) -> String {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var tokens = tokenize(trimmed)
        tokens = removeFillers(tokens)
        tokens = collapseRepeats(tokens)
        tokens = collapseStutters(tokens)
        guard !tokens.isEmpty else { return "" }

        tokens = capitalizeKnownWords(tokens)
        var text = reassemble(tokens)
        text = tidyCommas(text)
        text = capitalizeSentences(text)
        text = fixStandaloneI(text)
        text = fixStrayCapitals(text)
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

    /// Collapses a stutter where the speaker restarts a word: "st stop",
    /// "comp computer", "fri friday".
    ///
    /// The fragment must be a strict prefix of the next word **and not itself a
    /// real word**. That exclusion is the whole safety margin: "to today" has
    /// exactly the same shape as a stutter, but "go to today's meeting" is
    /// ordinary English and dropping "to" would wreck it. Stutters on real words
    /// are left to `LearnedCorrections`, where the user confirms them in context.
    private func collapseStutters(_ tokens: [String]) -> [String] {
        guard tokens.count > 1 else { return tokens }
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            let current = tokens[index]
            let bare = current.lowercased().trimmingCharacters(in: .punctuationCharacters)

            if index + 1 < tokens.count, !bare.isEmpty, bare.count <= 4 {
                let next = tokens[index + 1].lowercased()
                    .trimmingCharacters(in: .punctuationCharacters)
                let isFragment = next.count > bare.count
                    && next.hasPrefix(bare)
                    && !Self.realWords.contains(bare)
                    && !current.contains(where: \.isPunctuation)
                if isFragment {
                    index += 1   // drop the fragment, keep the full word
                    continue
                }
            }
            out.append(current)
            index += 1
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

    /// Repairs comma damage that is wrong under any policy, then applies the
    /// chosen policy.
    ///
    /// Removing a filler strands its punctuation — "um, so" becomes ", so" —
    /// which is why this must run after filler removal, not before.
    private func tidyCommas(_ text: String) -> String {
        var out = text

        // Mechanical repairs, always correct.
        out = out.replacingOccurrences(of: "\\s*,\\s*,+", with: ",",
                                       options: [.regularExpression])   // ",  ," -> ","
        out = out.replacingOccurrences(of: "^\\s*,\\s*", with: "",
                                       options: [.regularExpression])   // leading comma
        out = out.replacingOccurrences(of: "\\s+,", with: ",",
                                       options: [.regularExpression])   // " ," -> ","
        out = out.replacingOccurrences(of: ",\\s*([.!?])", with: "$1",
                                       options: [.regularExpression])   // ", ." -> "."
        out = out.replacingOccurrences(of: ",\\s*$", with: "",
                                       options: [.regularExpression])   // trailing comma

        guard commaPolicy == .sparse else { return out }

        let words = out.split(whereSeparator: \.isWhitespace).map(String.init)

        // A list ("apples, oranges, and pears") puts commas between items that
        // are not clause markers. Detect the serial pattern — a comma followed
        // later by ", and" / ", or" — and keep every comma in that run, or the
        // list collapses into a single run-on phrase.
        let looksLikeList: Bool = {
            var commaCount = 0
            var hasSerial = false
            for (index, word) in words.enumerated() where word.hasSuffix(",") {
                commaCount += 1
                if index + 1 < words.count {
                    let next = words[index + 1].lowercased()
                    if next == "and" || next == "or" || next == "nor" { hasSerial = true }
                }
            }
            return commaCount >= 2 && hasSerial
        }()
        if looksLikeList { return out }

        // Otherwise keep a comma only when the next word actually starts a clause.
        var result: [String] = []
        for (index, word) in words.enumerated() {
            guard word.hasSuffix(","), index + 1 < words.count else {
                result.append(word)
                continue
            }
            let next = words[index + 1]
                .trimmingCharacters(in: .punctuationCharacters).lowercased()
            result.append(Self.clauseMarkers.contains(next) ? word : String(word.dropLast()))
        }
        return result.joined(separator: " ")
    }

    /// Lowercases a capital that appears mid-clause with no punctuation before it.
    ///
    /// Apple's transcriber capitalizes after a prosodic pause even when it emits
    /// no terminal punctuation, producing "we should ship it Today" — a capital
    /// that is ungrammatical on its face. Only words that can never be proper
    /// nouns are touched, so real names survive.
    ///
    /// A capital that *does* follow a full stop is left alone: there is no way
    /// to tell a real sentence break from a pause-induced one, and deleting a
    /// legitimate boundary is the worse error.
    private func fixStrayCapitals(_ text: String) -> String {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count > 1 else { return text }

        for index in 1..<words.count {
            let previous = words[index - 1]
            // Punctuation before it means the capital is justified.
            if previous.hasSuffix(".") || previous.hasSuffix("!")
                || previous.hasSuffix("?") || previous.hasSuffix(":") { continue }

            let word = words[index]
            let bare = word.trimmingCharacters(in: .punctuationCharacters)
            guard let first = bare.first, first.isUppercase,
                  bare != "I", bare.dropFirst().allSatisfy({ !$0.isUppercase }),
                  Self.neverProperNouns.contains(bare.lowercased())
            else { continue }

            let trailing = word.suffix(word.count - bare.count)
            words[index] = bare.prefix(1).lowercased() + bare.dropFirst() + trailing
        }
        return words.joined(separator: " ")
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
