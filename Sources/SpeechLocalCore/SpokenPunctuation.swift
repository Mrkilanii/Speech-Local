import Foundation

/// Spoken punctuation becomes the mark: "comma" is `,`, "slash" is `/`.
///
/// The recognizer does some of this itself, from the pause around the word —
/// but only some, and not predictably. One dictation of the same sentence came
/// back as "Three, four." and the next as "Three comma four.", so the word
/// reaches the transcript often enough to need handling here.
///
///     "hello comma world"      ->  "hello, world"
///     "read me dot txt"        ->  "read me.txt"   (nothing added around it)
///     "and slash or"           ->  "and/or"
///     "done full stop"         ->  "done."
///     "one space two"          ->  "one two"
///
/// The escape hatch is the same as for numbers: **spell the word** and it stays
/// a word. "C-O-M-M-A" is "comma", because `SpelledWords` runs after this and
/// nothing re-reads what it produces.
///
/// The unavoidable problem is that most of these are ordinary words too — "the
/// comma is missing", "we are out of disk space", "a dash of salt". The guard
/// is grammatical rather than acoustic, since the pause is gone by the time the
/// text arrives: a punctuation word used as a **noun** has a determiner in
/// front of it, and one used as a **command** does not. That keeps "add a
/// comma" and converts "hello comma world", which is the split that matters.
///
/// It is a heuristic and it will be wrong sometimes — "storage space" is a noun
/// with no determiner. Spelling the word is always available, and `commands`
/// below is one table to edit.
enum SpokenPunctuation {
    /// How a mark attaches to the words around it.
    enum Glue: Equatable {
        /// Replaces the previous word's trailing punctuation: "hello, world".
        /// An empty mark simply drops the spoken word, which is what "space"
        /// wants — the tokens already have a space between them.
        case trailing(String)
        /// Binds the words on either side with no spaces: "and/or", "me.txt".
        case joining(String)
        /// Opens the word that follows: "(like this".
        case leading(String)
    }

    /// Every phrase is matched on its bare words, longest first, so "full stop"
    /// wins over a bare "stop" — which is not in the table at all, being far
    /// more often a verb.
    static let commands: [String: Glue] = [
        // Sentence punctuation.
        "comma": .trailing(","),
        "period": .trailing("."),
        "full stop": .trailing("."),
        "fullstop": .trailing("."),
        "question mark": .trailing("?"),
        "exclamation mark": .trailing("!"),
        "exclamation point": .trailing("!"),
        "colon": .trailing(":"),
        "semicolon": .trailing(";"),
        "semi colon": .trailing(";"),
        "ellipsis": .trailing("…"),

        // Marks that bind two words together.
        "slash": .joining("/"),
        "forward slash": .joining("/"),
        "backslash": .joining("\\"),
        "back slash": .joining("\\"),
        "hyphen": .joining("-"),
        "dash": .joining("-"),
        "underscore": .joining("_"),
        "dot": .joining("."),
        "at sign": .joining("@"),
        "at symbol": .joining("@"),
        "ampersand": .joining("&"),
        "asterisk": .joining("*"),
        "plus sign": .joining("+"),
        "equals sign": .joining("="),
        "percent sign": .joining("%"),
        "caret": .joining("^"),
        "tilde": .joining("~"),
        "vertical bar": .joining("|"),

        // Marks that open what follows. "Bracket" is a paren here: that is
        // what it means everywhere outside a compiler, and it is what someone
        // numbering a list out loud has in mind.
        "open paren": .leading("("),
        "open parenthesis": .leading("("),
        "open bracket": .leading("("),
        "open square bracket": .leading("["),
        "dollar sign": .leading("$"),
        "hashtag": .leading("#"),
        "hash sign": .leading("#"),
        "pound sign": .leading("#"),

        // Marks that close what came before. A bare "bracket" is the one used
        // when numbering by voice — "one bracket, do this" — so it closes.
        "bracket": .trailing(")"),
        "close paren": .trailing(")"),
        "closed paren": .trailing(")"),
        "close parenthesis": .trailing(")"),
        "close bracket": .trailing(")"),
        "closed bracket": .trailing(")"),
        "close square bracket": .trailing("]"),

        // The word is the instruction; the space is already there.
        "space": .trailing(""),
    ]

    /// The longest phrase in `commands`, in words.
    static let longestPhrase = commands.keys
        .map { $0.split(separator: " ").count }.max() ?? 1

    /// Words that make the next word a noun rather than an instruction.
    /// Determiners and quantifiers, plus the few collocations common enough to
    /// be worth naming ("disk space", "white space").
    static let nounFrame: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your",
        "his", "her", "its", "our", "their", "some", "any", "no", "every",
        "each", "another", "more", "less", "much", "many", "enough", "extra",
        "free", "white", "disk", "blank", "storage", "of", "without", "with",
        "one", "two", "three", "first", "last", "next", "same", "other",
    ]

    /// Whether a bare word could open a command. Used by the comma policy,
    /// which runs first and must not strip the punctuation that tells a
    /// dictated command from the ordinary word ("leave one space, two of
    /// them" is a sentence; "hello comma world" is not).
    static func isCommandWord(_ word: String) -> Bool {
        let lowered = word.lowercased()
        return commands[lowered] != nil
            || commands.keys.contains { $0.hasPrefix(lowered + " ") }
    }

    /// Single-word commands, for `SpelledWords` to protect.
    static var spellableWords: Set<String> {
        Set(commands.keys.filter { !$0.contains(" ") })
    }

    /// Which opening mark each closing mark answers.
    static let opener: [String: String] = [")": "(", "]": "["]

    private struct Command {
        var glue: Glue
        var consumed: Int
    }

    static func apply(to tokens: [String]) -> [String] {
        var out: [String] = []
        var prefix = ""          // an opening mark waiting for its word
        var open: [String] = []  // opening marks still unclosed
        var index = 0

        while index < tokens.count {
            let command = match(tokens, at: index)
            // A closer with its opener already in the text is certainly the
            // command, whatever precedes it — "this" would otherwise read
            // "close paren" as a noun phrase and leave it in the sentence.
            let closes = command.map { closing($0, open: open) } ?? false

            guard let command,
                  closes || !isNounUse(previous: out.last, prefix: prefix),
                  rewrite(command, into: &out, tokens: tokens,
                          following: index + command.consumed, prefix: &prefix)
            else {
                out.append(prefix + tokens[index])
                prefix = ""
                index += 1
                continue
            }
            index += command.consumed
            // A joining mark swallows the word after it too.
            if case .joining = command.glue { index += 1 }

            let mark = mark(of: command.glue)
            if case .leading = command.glue, opener.values.contains(mark) {
                open.append(mark)
            } else if let match = opener[mark], let last = open.lastIndex(of: match) {
                open.remove(at: last)
            }
        }

        // An opening mark with nothing after it was never an instruction.
        if !prefix.isEmpty { out.append(prefix) }
        return out
    }

    /// The longest command starting at this token, if any.
    private static func match(_ tokens: [String], at index: Int) -> Command? {
        for length in stride(from: min(longestPhrase, tokens.count - index),
                             through: 1, by: -1) {
            let phrase = tokens[index..<(index + length)]
                .map(Token.word).joined(separator: " ")
            // Punctuation inside a phrase means the words are not one command.
            let broken = tokens[index..<(index + length - 1)]
                .contains { !Token.parts(of: $0).trailing.isEmpty }
            guard !broken, let glue = commands[phrase] ?? plural(of: phrase)
            else { continue }
            // Punctuation after it is allowed only when it says the same thing
            // the word does — the recognizer marks a spoken comma twice. A
            // different mark means the word is doing its own work: "leave one
            // space, two of them" is a sentence.
            //
            // The exception is the full stop that ends the whole utterance,
            // which the recognizer adds to whatever came last and which says
            // nothing about the word. Not extended to a command that writes
            // nothing: "give me space." would lose its last word.
            let mark = mark(of: glue)
            let trailing = Token.parts(of: tokens[index + length - 1]).trailing
            let endsUtterance = index + length == tokens.count
                && !mark.isEmpty && trailing.count == 1
                && ".!?".contains(trailing)
            if trailing.isEmpty || trailing == mark || endsUtterance {
                return Command(glue: glue, consumed: length)
            }
        }
        return nil
    }

    /// Whether this command closes an opening mark already in the text.
    private static func closing(_ command: Command, open: [String]) -> Bool {
        guard case .trailing(let mark) = command.glue,
              let match = opener[mark] else { return false }
        return open.contains(match)
    }

    /// The command a plural spells, if any.
    ///
    /// The recognizer applies grammar to what it hears: say "two close
    /// bracket" and it writes "Two close brackets." Nothing can be dictated
    /// after a number without this.
    ///
    /// A plural never matches a command that writes nothing — "two spaces"
    /// would lose the word altogether, and a word vanishing is the one outcome
    /// the speaker cannot see to undo.
    private static func plural(of phrase: String) -> Glue? {
        var words = phrase.split(separator: " ").map(String.init)
        guard let last = words.popLast() else { return nil }

        for singular in [last.dropLast(2), last.dropLast(1)] where last.count > 3 {
            let candidate = (words + [String(singular)]).joined(separator: " ")
            if let glue = commands[candidate], !mark(of: glue).isEmpty { return glue }
        }
        return nil
    }

    private static func mark(of glue: Glue) -> String {
        switch glue {
        case .trailing(let mark), .joining(let mark), .leading(let mark): return mark
        }
    }

    /// Whether the word is being used as a noun, and so left alone.
    private static func isNounUse(previous: String?, prefix: String) -> Bool {
        guard prefix.isEmpty, let previous else { return false }
        let parts = Token.parts(of: previous)
        // A determiner only governs the next word if nothing punctuates
        // between them: "the comma" is a noun, "wait, the comma" still is.
        return nounFrame.contains(parts.core.lowercased())
    }

    /// Applies the mark. Returns false when there is nothing to attach it to,
    /// in which case the spoken word stays a word.
    private static func rewrite(
        _ command: Command, into out: inout [String],
        tokens: [String], following: Int, prefix: inout String
    ) -> Bool {
        switch command.glue {
        case .trailing(let mark):
            guard prefix.isEmpty, let last = out.last else { return false }
            let parts = Token.parts(of: last)
            out[out.count - 1] = parts.leading + parts.core + mark
            return true

        case .joining(let mark):
            guard prefix.isEmpty, let last = out.last,
                  let next = tokens[safe: following] else { return false }
            let left = Token.parts(of: last)
            let right = Token.parts(of: next)
            guard !left.core.isEmpty, !right.core.isEmpty else { return false }
            out[out.count - 1] =
                left.leading + left.core + mark + right.core + right.trailing
            return true

        case .leading(let mark):
            guard tokens[safe: following] != nil else { return false }
            prefix += mark
            return true
        }
    }
}
