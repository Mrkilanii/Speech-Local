import Foundation

/// Removes "like" and "you know" when the recognizer has fenced them off with
/// commas.
///
///     "So, like, you know, we ship."  ->  "So we ship."
///
/// `RulesCleanup` deliberately never removes these: "I like apples" and "you
/// know the answer" are content, and a filler list keyed on the word alone
/// would eat them. The comma is what separates the two. It is the recognizer
/// reporting a pause on both sides, and in the dictation log `, like,`
/// appeared in 321 of 2,848 lines and `, you know,` in 112, with none of the
/// 55 sampled hits meaning "such as".
///
/// A phrase is removed only when all of these hold, because each one alone is
/// satisfied by ordinary prose:
///
/// 1. **It opens a clause** — first in the text, or right after a token ending
///    in `,` `.` `!` or `?`. "I would like, if possible, a table" fails here.
/// 2. **It is closed by exactly one comma.** "It was fine, like," with nothing
///    after it is left alone: there is no evidence the sentence went on.
/// 3. **Nothing is wrapped around it** — no punctuation before any of its
///    words, none between "you" and "know".
///
/// The known cost is "fruits, like, apples", where "like" means "such as" and
/// is removed anyway. The tests pin it so the trade stays visible.
///
/// Capitalisation is not touched: `RulesCleanup` runs next and owns it.
public enum DiscourseFillers {
    /// Each phrase as its lowercased words.
    static let phrases: [[String]] = [["like"], ["you", "know"]]

    public static func apply(_ text: String) -> String {
        let tokens = Token.split(text)
        let marked = markedIndices(in: tokens)
        // Nothing matched: hand back the exact input, whitespace and all, so
        // this stage is invisible to every utterance it does not touch.
        guard !marked.isEmpty else { return text }

        var out: [String] = []
        var index = 0
        while index < tokens.count {
            guard marked.contains(index) else {
                out.append(tokens[index])
                index += 1
                continue
            }
            // The comma before the run was the opening half of the fence. With
            // the phrase gone it would split a clause that is now continuous:
            // "Where, there is" is wrong where "Where there is" is not.
            if let last = out.last {
                let previous = Token.parts(of: last)
                if previous.trailing == "," {
                    out[out.count - 1] = previous.leading + previous.core
                }
            }
            while index < tokens.count, marked.contains(index) { index += 1 }
        }
        return Token.join(out)
    }

    /// Every token belonging to a matched phrase, judged on the original
    /// tokens. Deciding on the original text is what lets "like, you know,"
    /// both go: the second phrase's opening comma is the first phrase's closing
    /// one.
    private static func markedIndices(in tokens: [String]) -> Set<Int> {
        var marked = Set<Int>()
        for start in tokens.indices {
            for phrase in phrases where matches(phrase, in: tokens, at: start) {
                marked.formUnion(start..<(start + phrase.count))
            }
        }
        return marked
    }

    private static func matches(_ phrase: [String], in tokens: [String], at start: Int) -> Bool {
        let end = start + phrase.count          // one past the phrase
        // A phrase with nothing after it is not a filler in a sentence.
        guard end < tokens.count else { return false }

        for (offset, word) in phrase.enumerated() {
            let parts = Token.parts(of: tokens[start + offset])
            guard parts.core.lowercased() == word, parts.leading.isEmpty else { return false }
            let isLast = offset == phrase.count - 1
            guard parts.trailing == (isLast ? "," : "") else { return false }
        }
        return opensClause(tokens, at: start)
    }

    private static func opensClause(_ tokens: [String], at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let last = Token.parts(of: tokens[index - 1]).trailing.last else { return false }
        return ",.!?".contains(last)
    }
}
