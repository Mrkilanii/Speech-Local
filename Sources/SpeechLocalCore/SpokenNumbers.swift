import Foundation

/// Spoken numbers become digits; spelled-out numbers stay words.
///
/// Apple's recognizer writes a dictated figure as a word — say "1" and the
/// transcript reads "one" — and there is no way to ask it for the digit by
/// voice. Since dictation is mostly used for prose *with figures in it*
/// (versions, counts, times, amounts), the digit is the form the user meant.
///
/// That leaves no way to type the word, so spelling it is the escape hatch.
/// A run of single letters is joined back into the word it spells, and only
/// when the result is a number word — joining arbitrary letter runs would
/// silently turn "U S A" into "usa".
///
///     "one"            ->  "1"
///     "twenty three"   ->  "23"
///     "two thousand"   ->  "2000"
///     "three four"     ->  "34"      (adjacent digits run together)
///     "one oh five"    ->  "105"
///     "three comma four" ->  "3, 4"  (say "comma" or "space" to break a run)
///     "three space four" ->  "3 4"
///     "o n e"          ->  "one"
///     "O-N-E"          ->  "one"
///
/// Reading adjacent digits as one figure is what makes codes, extensions and
/// account numbers dictatable — "four four seven two" is `4472`, the way it
/// would be typed. A spoken "comma" or "space" is how you say that two figures
/// really are two figures.
///
/// Two deliberate limitations:
///
/// * **Context decides the ambiguous words.** "one" is also a pronoun and "two"
///   is what the recognizer writes for a misheard "to", so both have an
///   exception list (below). Outside those frames the digit wins, because a
///   user dictating a figure is the case this exists for — and spelling the
///   word is always available when the list gets it wrong.
/// * **"and" is not consumed.** "one hundred and five" becomes "100 and 5",
///   not "105". Swallowing "and" would also collapse "three and four" into 34
///   with no way to ask for the two figures. Dictate `105` as "one oh five".
enum SpokenNumbers {
    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
        "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    /// "hundred" is handled separately: it multiplies the pending value rather
    /// than closing a group, so "five hundred thousand" works.
    static let scales: [String: Int] = [
        "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000,
    ]

    static let allWords: Set<String> =
        Set(units.keys).union(tens.keys).union(scales.keys).union(["hundred"])

    /// Words that are a single digit when read out as a sequence. "oh" and the
    /// letter "o" are here because that is how everyone says a zero inside a
    /// code — both are heavily guarded below, since "oh" is far more often an
    /// interjection than a digit.
    static let digitWords: [String: Character] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2", "three": "3",
        "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9",
    ]

    /// Spoken separators that break a digit run, and what each leaves behind.
    ///
    /// Only recognized **between two digits**. Elsewhere these are ordinary
    /// words ("the comma is missing", "we are out of disk space"), and
    /// rewriting them there would be a dictation command this app does not
    /// have. Between two digits neither word has any other reading.
    static let separators: [String: String] = ["comma": ",", "space": ""]

    /// Frames in which a number word is not a figure and must stay a word.
    ///
    /// Only a number spoken **on its own** is checked: "twenty one" and "one
    /// hundred" are unambiguously figures, so a multi-word phrase is never
    /// excepted. The frame is also ignored when punctuation separates the two
    /// words — in "I have two, the rest are gone" the "the" is a new clause,
    /// not part of the phrase.
    ///
    /// * **"one"** doubles as a pronoun and a vague quantifier: "this one",
    ///   "one more", "no one", "one of them", "one day".
    /// * **"two"** is what the recognizer writes when it mishears "to". It
    ///   cannot be repaired here (that is `LearnedCorrections`' job, with the
    ///   user confirming), but leaving the word is strictly better than
    ///   committing to "2 the".
    static let exceptions: [String: (before: Set<String>, after: Set<String>)] = [
        "one": (
            before: ["no", "the", "this", "that", "which", "each", "every",
                     "any", "another", "only", "such", "some", "loved", "little"],
            after: ["of", "another", "who", "whom", "by", "more", "thing",
                    "things", "day", "way", "time", "point", "side"]
        ),
        "two": (
            before: [],
            after: ["be", "do", "go", "get", "make", "see", "have", "know",
                    "say", "take", "come", "give", "put", "find", "tell",
                    "ask", "use", "try", "keep", "let", "start", "stop",
                    "talk", "the", "me", "you", "him", "her", "us", "them", "it"]
        ),
    ]

    private struct Match {
        var text: String
        var consumed: Int
    }

    /// Rewrites number words in a token stream. Must run before any step that
    /// merges adjacent tokens — "t h r e e" contains an "e e" that de-duplication
    /// would otherwise eat.
    static func apply(to tokens: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < tokens.count {
            if let match = spelled(tokens, at: index) {
                out.append(match.text)
                index += match.consumed
                continue
            }
            if let match = digitSequence(tokens, at: index) {
                out.append(match.text)
                index += match.consumed
                continue
            }
            if let match = spoken(tokens, at: index, previous: out.last) {
                out.append(match.text)
                index += match.consumed
                continue
            }
            out.append(tokens[index])
            index += 1
        }
        return out
    }

    // MARK: - Digit sequences

    /// Reads a run of adjacent single digits as one figure: "four four seven
    /// two" is `4472`, not four separate numbers.
    ///
    /// Tried before `spoken` because the two disagree — the arithmetic reading
    /// of "three four" is two numbers, and the sequence reading is 34, which is
    /// what someone dictating a figure meant. A run that leads into a scale
    /// word is handed back, so "five hundred" stays arithmetic.
    private static func digitSequence(_ tokens: [String], at index: Int) -> Match? {
        var digits = ""
        var leading = ""
        var trailing = ""
        var consumed = 0
        var brokeOnSeparator = false
        var cursor = index

        while cursor < tokens.count {
            let piece = parts(of: tokens[cursor])
            let word = piece.core.lowercased()
            guard let digit = digitWords[word] else { break }

            if cursor == index { leading = piece.leading }
            else if !piece.leading.isEmpty { break }

            // "oh"/"o" is a zero only when another digit follows it directly.
            // Without this, "five o clock" reads as 50 and "oh, two more"
            // loses its interjection.
            if digit == "0", word != "zero" {
                guard piece.trailing.isEmpty,
                      let next = tokens[safe: cursor + 1],
                      digitWords[parts(of: next).core.lowercased()] != nil
                else { break }
            }

            digits.append(digit)
            trailing = piece.trailing
            consumed += 1
            cursor += 1
            if !trailing.isEmpty { break }

            // A spoken "comma" or "space" ends this figure and starts the next.
            if let next = tokens[safe: cursor],
               let separator = separators[parts(of: next).core.lowercased()],
               let following = tokens[safe: cursor + 1],
               digitWords[parts(of: following).core.lowercased()] != nil {
                trailing = separator
                consumed += 1
                brokeOnSeparator = true
                break
            }
        }

        // A lone digit is the arithmetic case — let `spoken` handle it, so its
        // exception frames still apply. The exception is a spoken separator,
        // which has to be consumed here or it stays in the text as a word.
        guard digits.count >= 2 || brokeOnSeparator else { return nil }

        // "one oh five" is a sequence; "one hundred" is arithmetic.
        if let next = tokens[safe: index + consumed],
           trailing.isEmpty,
           scales[parts(of: next).core.lowercased()] != nil
               || parts(of: next).core.lowercased() == "hundred" {
            return nil
        }

        // A run opening on "oh" needs to be long enough to be a code: "oh two
        // one" is an area code, "oh two years ago" is not a number at all.
        if digits.first == "0", parts(of: tokens[index]).core.lowercased() != "zero",
           digits.count < 3 {
            return nil
        }

        return Match(text: leading + digits + trailing, consumed: consumed)
    }

    // MARK: - Spoken -> digits

    private static func spoken(
        _ tokens: [String], at index: Int, previous: String?
    ) -> Match? {
        var accumulator = Accumulator()
        var words: [String] = []
        var leading = ""
        var trailing = ""
        var consumed = 0
        var cursor = index

        while cursor < tokens.count {
            let piece = parts(of: tokens[cursor])
            guard !piece.core.isEmpty else { break }
            // "twenty-three" arrives as one token.
            let spelling = piece.core.split(separator: "-").map { $0.lowercased() }
            guard !spelling.isEmpty else { break }

            // Punctuation before a word ends the phrase: "(three" starts fresh.
            if cursor == index { leading = piece.leading }
            else if !piece.leading.isEmpty { break }

            // All-or-nothing per token, so the token boundary stays intact when
            // the phrase cannot legally continue ("five five" is two numbers).
            var trial = accumulator
            var accepted = true
            for word in spelling where accepted {
                accepted = trial.accept(word)
            }
            guard accepted else { break }

            accumulator = trial
            words.append(contentsOf: spelling)
            trailing = piece.trailing
            consumed += 1
            cursor += 1
            if !trailing.isEmpty { break }   // ", " closes the number
        }

        guard consumed > 0, accumulator.started else { return nil }

        if words.count == 1, let frame = exceptions[words[0]],
           isException(frame, previous: previous,
                       next: trailing.isEmpty ? tokens[safe: index + consumed] : nil) {
            return nil
        }
        return Match(text: leading + String(accumulator.value) + trailing,
                     consumed: consumed)
    }

    private static func isException(
        _ frame: (before: Set<String>, after: Set<String>),
        previous: String?, next: String?
    ) -> Bool {
        if let previous, parts(of: previous).trailing.isEmpty,
           frame.before.contains(parts(of: previous).core.lowercased()) {
            return true
        }
        if let next, frame.after.contains(parts(of: next).core.lowercased()) {
            return true
        }
        return false
    }

    /// Consumes number words left to right, rejecting anything that is not a
    /// grammatical continuation. Rejection is what keeps "five five five" three
    /// numbers instead of one.
    private struct Accumulator {
        var total = 0
        var current = 0
        var hasUnit = false
        var hasTen = false
        var hasHundred = false
        var lastScale = Int.max
        var started = false

        var value: Int { total + current }

        mutating func accept(_ word: String) -> Bool {
            if let unit = SpokenNumbers.units[word] {
                // After a ten only 1–9 can follow: "twenty one", not "twenty ten".
                guard !hasUnit, !hasTen || (1...9).contains(unit) else { return false }
                current += unit
                hasUnit = true
                started = true
                return true
            }
            if let ten = SpokenNumbers.tens[word] {
                guard !hasUnit, !hasTen else { return false }
                current += ten
                hasTen = true
                started = true
                return true
            }
            // A scale word cannot open a number: bare "hundred" or "thousand" is
            // far more often a vague quantity than a figure.
            guard started else { return false }
            if word == "hundred" {
                guard !hasHundred, current > 0, current < 100 else { return false }
                current *= 100
                hasHundred = true
                hasUnit = false
                hasTen = false
                return true
            }
            if let scale = SpokenNumbers.scales[word] {
                // Scales must descend: "two million three thousand", never the reverse.
                guard current > 0, scale < lastScale else { return false }
                total += current * scale
                lastScale = scale
                current = 0
                hasUnit = false
                hasTen = false
                hasHundred = false
                return true
            }
            return false
        }
    }

    // MARK: - Spelled -> word

    /// The shortest number word is three letters ("one"), the longest nine
    /// ("seventeen"). Bounds the prefix search.
    private static let shortestWord = 3
    private static let longestWord = 9

    private static func spelled(_ tokens: [String], at index: Int) -> Match? {
        // "O-N-E" / "o.n.e" — the recognizer kept it as one token.
        let first = parts(of: tokens[index])
        let pieces = first.core.split(whereSeparator: isLetterSeparator)
        if pieces.count >= shortestWord,
           pieces.allSatisfy({ $0.count == 1 && ($0.first?.isLetter ?? false) }) {
            let word = pieces.joined().lowercased()
            if allWords.contains(word) {
                return Match(text: first.leading + word + first.trailing, consumed: 1)
            }
        }

        // "o n e" — separate letters, possibly each with its own full stop.
        var letters: [String] = []
        var cursor = index
        while cursor < tokens.count, letters.count < longestWord {
            let piece = parts(of: tokens[cursor])
            guard piece.leading.isEmpty, piece.core.count == 1,
                  let letter = piece.core.first, letter.isLetter else { break }
            letters.append(letter.lowercased())
            cursor += 1
        }
        guard letters.count >= shortestWord else { return nil }

        // Longest match first, so "s i x t y" is "sixty" and not "six" + "ty".
        for length in stride(from: letters.count, through: shortestWord, by: -1) {
            let word = letters.prefix(length).joined()
            if allWords.contains(word) {
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

    // MARK: - Tokens

    /// Splits a token into edge punctuation and the word inside it, so the
    /// rewrite can put "(twenty-two," back together as "(22,".
    static func parts(of token: String) -> (leading: String, core: String, trailing: String) {
        var core = Substring(token)
        var leading = ""
        var trailing = ""
        while let first = core.first, !first.isLetter, !first.isNumber {
            leading.append(first)
            core = core.dropFirst()
        }
        while let last = core.last, !last.isLetter, !last.isNumber {
            trailing.insert(last, at: trailing.startIndex)
            core = core.dropLast()
        }
        return (leading, String(core), trailing)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
