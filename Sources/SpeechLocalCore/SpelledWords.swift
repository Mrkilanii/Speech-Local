import Foundation

/// Joins a run of spelled letters back into the word it spells.
///
/// This is the escape hatch for every rewrite that turns a word into a symbol.
/// Saying "one" gives `1` and saying "comma" gives `,`, which leaves no way to
/// dictate the words themselves — so spelling one out is how you ask for it:
///
///     "o n e"      ->  "one"
///     "O-N-E"      ->  "one"
///     "c o m m a"  ->  "comma"
///
/// It runs **after** the number and punctuation steps, and nothing re-reads
/// what it produces, so a spelled word cannot be converted back.
///
/// Deliberately narrow: only runs that spell a word those steps would have
/// eaten are joined. Joining every letter run would silently turn "U S A" into
/// "usa", and the point of this file is to give words back, not take them.
enum SpelledWords {
    static let vocabulary: Set<String> =
        SpokenNumbers.allWords.union(SpokenPunctuation.spellableWords)

    /// A run this short is more likely an accident than a spelling. Every word
    /// in the vocabulary is at least three letters, so nothing is lost.
    static let shortestWord = 3
    static let longestWord = vocabulary.map(\.count).max() ?? 3

    static func apply(to tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if let match = spelled(tokens, at: index) {
                out.append(match.text)
                index += match.consumed
                continue
            }
            out.append(tokens[index])
            index += 1
        }
        return out
    }

    private struct Match {
        var text: String
        var consumed: Int
    }

    private static func spelled(_ tokens: [String], at index: Int) -> Match? {
        // "O-N-E" — the recognizer kept the spelling as one token.
        let first = Token.parts(of: tokens[index])
        let pieces = first.core.split(whereSeparator: isLetterSeparator)
        if pieces.count >= shortestWord,
           pieces.allSatisfy({ $0.count == 1 && ($0.first?.isLetter ?? false) }) {
            let word = pieces.joined().lowercased()
            if vocabulary.contains(word) {
                return Match(text: first.leading + word + first.trailing, consumed: 1)
            }
        }

        // "o n e" — separate letters, possibly each with its own full stop.
        var letters: [String] = []
        var cursor = index
        while cursor < tokens.count, letters.count < longestWord {
            let piece = Token.parts(of: tokens[cursor])
            guard piece.leading.isEmpty, piece.core.count == 1,
                  let letter = piece.core.first, letter.isLetter else { break }
            letters.append(letter.lowercased())
            cursor += 1
        }
        guard letters.count >= shortestWord else { return nil }

        // Longest match first, so "s i x t y" is "sixty" and not "six" + "ty".
        for length in stride(from: letters.count, through: shortestWord, by: -1) {
            let word = letters.prefix(length).joined()
            if vocabulary.contains(word) {
                // The full stops between letters are spelling artifacts, not
                // sentence ends, so they are dropped with the letters.
                return Match(text: word, consumed: length)
            }
        }
        return nil
    }

    private static func isLetterSeparator(_ character: Character) -> Bool {
        character == "-" || character == "." || character == "\u{2010}"
            || character == "\u{2011}" || character == "\u{2013}"
    }
}
