import Foundation

/// Spoken Python becomes Python: one press of the code key is one line.
///
///     "car underscore two equals input quote what is your name"
///         ->  car_2 = input("what is your name")
///     "for i in range len numbers"      ->  for i in range(len(numbers)):
///     "d f equals p d dot read csv quote data dot csv"
///         ->  df = pd.read_csv("data.csv")
///     "plt dot show"                    ->  plt.show()
///
/// Rules, not the model, for the reason decision 01 gives and a sharper one:
/// in prose a wrong word is a typo, in code it is a program that does not run.
///
/// What the recognizer does to code decides most of this file, and it was
/// measured before a line was written (decision 10). It writes code as prose —
/// a capital on the first word, a full stop at the end, commas wherever the
/// speaker paused — and it turns some spoken commands into symbols itself
/// ("pd dot read" arrives as `pd.read`) and not others. So everything outside
/// a string is lowercased and stripped of prose punctuation, and Python's own
/// spelling is put back from `PythonNames`, a table generated from the
/// libraries themselves.
///
/// Four rules do the structural work:
///
/// * **A string runs to "close quote", or to the end of the line.** The words
///   inside are kept as the recognizer wrote them.
/// * **A function followed by a value is called**, and every bracket still
///   open at the end of the line is closed. "print len x" is `print(len(x))`;
///   "close" ends the innermost one early.
/// * **A line opened by a block keyword ends in a colon.**
/// * **Words that are not Python run together as one identifier**, because
///   two names side by side are never valid Python: "my list" is `my_list`.
///   After `class` they run together as `CapWords`.
public enum PythonDictation {
    /// One line of code, and how it sits relative to the line before.
    public struct Line: Equatable, Sendable {
        public let text: String
        /// Starts a new line. Only ever true because the speaker said "next line".
        public let breakBefore: Bool
        /// Levels to step out from where the line above left the indent.
        public let dedent: Int

        public init(text: String, breakBefore: Bool, dedent: Int) {
            self.text = text
            self.breakBefore = breakBefore
            self.dedent = dedent
        }
    }

    /// The whole dictation as text, for history and the copy panel.
    public static func apply(to transcript: String) -> String {
        let lines = lines(of: transcript)
        return (lines.first?.breakBefore == true ? "\n" : "")
            + lines.map(\.text).joined(separator: "\n")
    }

    // "next time" is how the recognizer heard "next line" once in a real
    // dictation, and `next(time)` is never what anyone dictating meant.
    static let lineBreaks: Set<String> = ["next line", "new line", "newline", "line break",
                                          "next time", "next lines"]
    // The recognizer does not know "dedent": Omar's came back as "D dent",
    // and "the dent" when said in a sentence. "step out" is plain English it
    // hears reliably.
    static let dedents: Set<String> = ["dedent", "unindent", "outdent", "out dent",
                                       "d dent", "the dent", "de dent", "dee dent", "step out",
                                       "step back"]

    /// Several lines in one press, split where the speaker said "next line".
    /// A dedent with no line break before it is dropped: there is no fresh
    /// line for it to apply to.
    public static func lines(of transcript: String) -> [Line] {
        let tokens = Token.split(transcript).filter { !fillers.contains(Token.word($0)) }
        var groups: [(tokens: [String], breakBefore: Bool, dedent: Int)] = [([], false, 0)]
        var pending = 0
        var index = 0
        while index < tokens.count {
            if let (_, length) = phrase(tokens, at: index, in: lineBreaks, longest: 2) {
                groups.append(([], true, pending))
                pending = 0
                index += length
                continue
            }
            if let (_, length) = phrase(tokens, at: index, in: dedents, longest: 2) {
                if groups[groups.count - 1].tokens.isEmpty {
                    groups[groups.count - 1].dedent += 1
                } else {
                    pending += 1
                }
                index += length
                continue
            }
            groups[groups.count - 1].tokens.append(tokens[index])
            index += 1
        }
        // A "next line" that opened the dictation leaves an empty first group.
        if groups.count > 1, groups[0].tokens.isEmpty { groups.removeFirst() }

        return groups.map { group in
            var words = openingKeyword(group.tokens.flatMap(unglueQuote))
            if let first = words.first { words = unglueMatch(first) + words.dropFirst() }
            let text = words.isEmpty ? "" : render(structure(shape(lex(words))))
            var dedent = group.breakBefore ? group.dedent : 0
            // `elif`, `else`, `except` and `finally` always sit one level out
            // from the line above — whether that was the `if` itself or its
            // body — so the Backspace is implied. More is only said aloud.
            if group.breakBefore, closesBlock(text) { dedent = max(dedent, 1) }
            return Line(text: text, breakBefore: group.breakBefore, dedent: dedent)
        }.filter { !$0.text.isEmpty || $0.breakBefore }
    }

    /// The lines as one piece of text, indented here.
    ///
    /// The first version pressed Return and Backspace and let the editor
    /// indent. In Trace Table (CodeMirror, in Arc) the Return landed without
    /// an indent, so each Backspace meant for `elif` deleted the line break
    /// instead, and every `elif` ended up glued to the `print` above it. What
    /// an editor does with synthetic keys is not something to depend on; a
    /// paste is inserted as written everywhere that matters.
    ///
    /// Four spaces a level, from the indentation of the line the caret is on
    /// when the app publishes it (`caretLine`), and from column 0 when not.
    public static func block(_ lines: [Line], caretLine: String?) -> String {
        let current = caretLine?.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let leading = current.prefix { $0 == " " || $0 == "\t" }
        var level = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
        var text = ""
        for (index, line) in lines.enumerated() {
            if line.breakBefore {
                if index == 0, current.trimmingCharacters(in: .whitespaces).hasSuffix(":") {
                    level += 1
                }
                level = max(0, level - line.dedent)
                text += "\n" + (line.text.isEmpty ? "" : String(repeating: "    ", count: level))
            }
            text += line.text
            if line.text.hasSuffix(":") { level += 1 }
        }
        return text
    }

    private static func closesBlock(_ text: String) -> Bool {
        text.hasPrefix("elif ") || text == "else:" || text.hasPrefix("except")
            || text == "finally:"
    }

    /// What the recognizer makes of the keywords that open a line, measured
    /// on Omar's voice: `elif` came back as "LF" six times out of seven and
    /// "L if" once; `else` as "L" and "LS". Only at the start of a line, and a
    /// bare "L" only when nothing but a colon follows it — `l = 5` is a name.
    ///
    /// "else if" and "otherwise" are here too: ordinary English the recognizer
    /// hears reliably, for when the keyword itself will not come through.
    static func openingKeyword(_ tokens: [String]) -> [String] {
        guard let first = tokens.first else { return tokens }
        let word = Token.word(first)
        let second = tokens.dropFirst().first.map(Token.word)
        let restAfter = { (count: Int) in Array(tokens.dropFirst(count)) }
        let onlyColonFollows = second == nil || second == "colon"

        if ["lf", "elf", "elif"].contains(word) { return ["elif"] + restAfter(1) }
        if ["l", "else", "otherwise"].contains(word), second == "if" { return ["elif"] + restAfter(2) }
        if ["ls", "els", "else", "otherwise"].contains(word) { return ["else"] + restAfter(1) }
        if word == "l", onlyColonFollows { return ["else"] + restAfter(1) }
        return tokens
    }

    /// "Matchmark" — the recognizer ran the keyword into the subject.
    static func unglueMatch(_ token: String) -> [String] {
        let parts = Token.parts(of: token)
        let lower = parts.core.lowercased()
        guard lower.hasPrefix("match"), lower.count > 6,
              !["matches", "matched", "matcher", "matching", "matchbox"].contains(lower)
        else { return [token] }
        return [parts.leading + "match", String(parts.core.dropFirst(5)) + parts.trailing]
    }

    static let fillers: Set<String> = ["um", "uh", "er", "erm", "ah", "hmm"]

    // MARK: - Units

    enum Kind: Equatable {
        case unknown, keyword, callable, type, attribute, module, indexer
    }

    enum Unit: Equatable {
        case word(String, Kind)
        case number(String)
        case text(String)
        case op(String)
        case open(String)
        /// An empty closer means "whatever is innermost".
        case close(String)
        /// Soft commas are the recognizer's pauses; `structure` keeps one only
        /// where it separates two values.
        case comma(hard: Bool)
        case colon
        case dot
        case glue(String)
        case capital
    }

    // MARK: - Lexing: tokens to units

    /// Spoken commands, matched on bare words, longest first. Every entry is a
    /// word that can no longer be an identifier, so ordinary words ("over",
    /// "power", "period") are left out on purpose.
    static let commands: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ unit: Unit, _ phrases: String...) {
            for phrase in phrases { table[phrase] = unit }
        }
        add(.open("("), "open paren", "open parenthesis", "open bracket",
            "open round bracket", "left paren", "taking")
        add(.close(")"), "close paren", "closed paren", "close parenthesis",
            "close bracket", "closed bracket", "right paren")
        add(.open("["), "open square", "open square bracket", "left square")
        add(.close("]"), "close square", "closed square", "close square bracket")
        add(.open("{"), "open curly", "open brace", "open curly brace", "left curly")
        add(.close("}"), "close curly", "closed curly", "close brace", "close curly brace")
        add(.close(""), "close", "closed")
        add(.comma(hard: true), "comma")
        add(.colon, "colon")
        add(.dot, "dot")
        add(.glue("_"), "underscore")
        add(.glue("__"), "double underscore", "dunder")
        add(.capital, "capital")
        add(.op("="), "equals", "equal", "is equals", "equal sign", "equals sign")
        add(.op("=="), "double equals", "equals equals", "is equal to", "equal to")
        add(.op("!="), "not equals", "not equal", "not equal to", "is not equal to")
        add(.op("+="), "plus equals")
        add(.op("-="), "minus equals")
        add(.op("*="), "times equals")
        add(.op("/="), "divide equals", "divided equals")
        // "or" is heard as "are", "your", or dropped: "greater than are equal
        // to", "greater than your equal to" and "greater than equal to" all
        // came from a real voice. "is greater
        // than" is English wrapped round the operator.
        for (words, mark) in [("greater than", ">"), ("less than", "<"), ("more than", ">")] {
            for lead in ["", "is "] {
                add(.op(mark), lead + words)
                for tail in [" or equal to", " or equals", " or equal", " are equal to",
                             " are equal", " your equal to", " you're equal to",
                             " equal to", " equals"] {
                    add(.op(mark + "="), lead + words + tail)
                }
            }
        }
        add(.op("+"), "plus")
        add(.op("-"), "minus", "negative")
        add(.op("*"), "times", "multiplied by")
        add(.op("/"), "divided by")
        add(.op("//"), "floor divide", "floor divided by")
        add(.op("%"), "modulo")
        add(.op("**"), "to the power of")
        add(.op("->"), "arrow")
        add(.op(":="), "walrus")
        return table
    }()

    static let commandPhrases = Set(commands.keys)
    static let longestCommand = commands.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// What opens a string: its prefix and quote character. Not "open quote":
    /// "with open quote" is `open("...")`, and the builtin has to win.
    static let stringOpeners: [String: String] = [
        "quote": "\"", "quotes": "\"", "quotation mark": "\"", "quotation marks": "\"",
        "double quote": "\"", "single quote": "'",
        "f string": "f\"", "f quote": "f\"",
    ]

    static let stringClosers: Set<String> = [
        "close quote", "closed quote", "end quote", "unquote",
        "quote", "quotes", "quotation mark", "quotation marks",
    ]

    /// Mishearings measured in the spike, where the words around them make the
    /// correction certain. A table, not a rule: add a row when a real
    /// dictation shows one.
    static let confusions: [(heard: [String], meant: [String])] = [
        (["for", "iron"], ["for", "i", "in"]),
        (["range", "lens"], ["range", "len"]),
    ]

    /// "quotedata.csv" — the recognizer ran the command into the next word.
    static func unglueQuote(_ token: String) -> [String] {
        let parts = Token.parts(of: token)
        let lower = parts.core.lowercased()
        let head = lower.split(separator: ".").first.map(String.init) ?? lower
        guard lower.hasPrefix("quote"), lower.count > 5,
              !["quoted", "quotes", "quoter", "quotation", "quotations"].contains(head)
        else { return [token] }
        return [parts.leading + "quote", String(parts.core.dropFirst(5)) + parts.trailing]
    }

    static func phrase(_ tokens: [String], at index: Int, in table: Set<String>,
                               longest: Int) -> (String, Int)? {
        for length in stride(from: min(longest, tokens.count - index), through: 1, by: -1) {
            let phrase = tokens[index..<(index + length)].map(Token.word).joined(separator: " ")
            if table.contains(phrase) { return (phrase, length) }
        }
        return nil
    }

    static func lex(_ raw: [String]) -> [Unit] {
        var tokens: [String] = []
        var index = 0
        outer: while index < raw.count {
            for (heard, meant) in confusions {
                let end = index + heard.count
                if end <= raw.count, raw[index..<end].map(Token.word) == heard {
                    tokens.append(contentsOf: meant.dropLast())
                    tokens.append(meant.last! + Token.parts(of: raw[end - 1]).trailing)
                    index = end
                    continue outer
                }
            }
            tokens.append(raw[index])
            index += 1
        }

        var units: [Unit] = []
        var code: [String] = []
        func flushCode() {
            guard !code.isEmpty else { return }
            units.append(contentsOf: lexCode(SpokenNumbers.apply(to: code)))
            code = []
        }

        let openers = Set(stringOpeners.keys)
        index = 0
        while index < tokens.count {
            let word = Token.word(tokens[index])
            // "close quote" with no string open is a stray closer.
            if ["close", "closed", "end"].contains(word),
               let next = tokens[safe: index + 1], ["quote", "quotes"].contains(Token.word(next)) {
                index += 2
                continue
            }
            guard let (opener, length) = phrase(tokens, at: index, in: openers, longest: 2) else {
                code.append(tokens[index])
                index += 1
                continue
            }
            flushCode()
            var cursor = index + length
            var content: [String] = []
            var closed = false
            while cursor < tokens.count {
                if let (_, closer) = phrase(tokens, at: cursor, in: stringClosers, longest: 2) {
                    cursor += closer
                    closed = true
                    break
                }
                content.append(tokens[cursor])
                cursor += 1
            }
            units.append(.text(literal(content, opener: stringOpeners[opener]!, closed: closed)))
            if closed {
                units.append(contentsOf: trailingUnits(
                    tokens[cursor - 1], next: tokens[safe: cursor], afterCommand: true))
            }
            index = cursor
        }
        flushCode()
        return units
    }

    private static func lexCode(_ tokens: [String]) -> [Unit] {
        var units: [Unit] = []
        var index = 0
        while index < tokens.count {
            if let (phrase, length) = self.phrase(
                tokens, at: index, in: commandPhrases, longest: longestCommand),
               // `f.close()` is a method, not a command.
               !(["close", "closed"].contains(phrase) && units.last == .dot) {
                units.append(commands[phrase]!)
                index += length
                units.append(contentsOf: trailingUnits(
                    tokens[index - 1], next: tokens[safe: index], afterCommand: true))
                continue
            }
            units.append(contentsOf: tokenUnits(tokens[index], next: tokens[safe: index + 1]))
            index += 1
        }
        return units
    }

    static let symbolOps: Set<String> = [
        "=", "==", "!=", "+", "-", "*", "/", "//", "%", "**", "<", ">", "<=", ">=",
        "+=", "-=", "*=", "/=", "->", ":=",
    ]

    private static func tokenUnits(_ token: String, next: String?) -> [Unit] {
        let parts = Token.parts(of: token)
        if parts.core.isEmpty {
            let symbol = parts.leading + parts.trailing
            if symbolOps.contains(symbol) { return [.op(symbol)] }
            return symbol.compactMap(bracket)
        }
        var units = parts.leading.compactMap(bracket)
        // "pd.read" and "self.name" arrive as one token.
        for (position, piece) in parts.core.split(
            separator: ".", omittingEmptySubsequences: false).enumerated() {
            if position > 0 { units.append(.dot) }
            guard !piece.isEmpty else { continue }
            units.append(piece.allSatisfy(\.isNumber)
                         ? .number(String(piece)) : .word(piece.lowercased(), .unknown))
        }
        units.append(contentsOf: trailingUnits(token, next: next, afterCommand: false))
        return units
    }

    private static func bracket(_ character: Character) -> Unit? {
        switch character {
        case "(", "[", "{": return .open(String(character))
        case ")", "]", "}": return .close(String(character))
        default: return nil
        }
    }

    /// What the punctuation hanging off a token means in code.
    ///
    /// Mostly nothing: the recognizer punctuates for a reader. A comma between
    /// figures is the one the speaker said ("ten comma one" arrives as "10,
    /// one"); any other comma is soft. A full stop is a dot only when a
    /// lowercase word follows it — "nn. linear" is `nn.linear`, and the full
    /// stop at the end of the line is prose.
    private static func trailingUnits(_ token: String, next: String?, afterCommand: Bool) -> [Unit] {
        let parts = Token.parts(of: token)
        // Between two figures the comma was spoken ("ten comma one"); after
        // the last one it was a pause ("greater than 50, and").
        let isFigure = !parts.core.isEmpty && parts.core.allSatisfy(\.isNumber)
            && next.map(SpokenNumbers.isFigure) == true
        var units: [Unit] = []
        for character in parts.trailing {
            switch character {
            case ",": units.append(.comma(hard: isFigure && !afterCommand))
            case ":": units.append(.colon)
            case ")", "]", "}": units.append(.close(String(character)))
            case ".":
                if !afterCommand, parts.trailing == ".", next?.first?.isLowercase == true {
                    units.append(.dot)
                }
            default: break
            }
        }
        return units
    }

    /// A string literal from the words spoken inside it.
    static func literal(_ words: [String], opener: String, closed: Bool) -> String {
        var body = SpokenPunctuation.apply(to: capitals(words))
        if opener.hasPrefix("f") { body = interpolate(body) }
        var text = body.joined(separator: " ")
        // The pause around the spoken "quote" gets a comma or a full stop.
        while let first = text.first, ",.".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        while text.last == "," { text.removeLast() }
        // Running to the end of the line, a final full stop is the
        // recognizer ending its sentence. A question mark is kept: it is far
        // more often part of a prompt than an accident.
        if !closed, text.hasSuffix("."), !text.hasSuffix("..") { text.removeLast() }
        let quote = opener.last!
        return opener
            + text.replacingOccurrences(of: String(quote), with: "\\\(quote)")
            + String(quote)
    }

    /// "capital a" is `A`; "all caps hello" is `HELLO`. Inside a string the
    /// recognizer's own capitals are kept, but it writes a lone letter
    /// however it likes, so saying which case is the only reliable way.
    static func capitals(_ words: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = Token.word(words[index])
            let length = word == "all" && Token.word(words[safe: index + 1] ?? "") == "caps" ? 2
                : word == "capital" ? 1 : 0
            guard length > 0, let target = words[safe: index + length] else {
                out.append(words[index])
                index += 1
                continue
            }
            let parts = Token.parts(of: target)
            let core = length == 2 ? parts.core.uppercased()
                : parts.core.prefix(1).uppercased() + parts.core.dropFirst()
            out.append(parts.leading + core + parts.trailing)
            index += length + 1
        }
        return out
    }

    /// "curly name close curly" inside an f-string is `{name}`.
    private static func interpolate(_ words: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < words.count {
            let word = Token.word(words[index])
            let opensWithOpen = word == "open" && Token.word(words[safe: index + 1] ?? "") == "curly"
            guard word == "curly" || opensWithOpen else {
                out.append(words[index])
                index += 1
                continue
            }
            var cursor = index + (opensWithOpen ? 2 : 1)
            var inner: [String] = []
            while cursor < words.count {
                if ["close", "closed"].contains(Token.word(words[cursor])),
                   Token.word(words[safe: cursor + 1] ?? "") == "curly" {
                    cursor += 2
                    break
                }
                inner.append(words[cursor])
                cursor += 1
            }
            out.append("{" + apply(to: inner.joined(separator: " ")) + "}")
            index = cursor
        }
        return out
    }

    // MARK: - Shaping: words to names

    static let blockKeywords: Set<String> = [
        "if", "elif", "else", "for", "while", "try", "except", "finally", "with",
        "def", "class", "match", "case",
    ]

    /// Keywords only at the start of a line; elsewhere ordinary names.
    static let softKeywords: Set<String> = ["match", "case"]

    static let indexers: Set<String> = ["iloc", "loc", "iat", "at"]

    static func shape(_ input: [Unit]) -> [Unit] {
        let names = PythonNameIndex.shared

        // Explicit joins and capitals: "car underscore 2", "dunder init".
        var units: [Unit] = []
        var index = 0
        while index < input.count {
            switch input[index] {
            case .glue(let mark):
                let right = spelling(input[safe: index + 1])
                let left = spelling(units.last)
                let leftIsName = left.map { !names.isKeyword($0) } ?? false
                let rightIsName = right.map { !names.isKeyword($0) } ?? false
                if mark == "__", let right, rightIsName, !leftIsName {
                    units.append(.word("__" + right + "__", .unknown))
                    index += 2
                } else if let left, let right, leftIsName, rightIsName {
                    units[units.count - 1] = .word(left + mark + right, .unknown)
                    index += 2
                } else {
                    // A bare underscore: the wildcard in `case _`.
                    if mark == "_" { units.append(.word("_", .unknown)) }
                    index += 1
                }
            case .capital:
                if case .word(let word, _)? = input[safe: index + 1] {
                    units.append(.word(word.prefix(1).uppercased() + word.dropFirst(), .unknown))
                    index += 2
                } else {
                    index += 1
                }
            default:
                units.append(input[index])
                index += 1
            }
        }

        // Letters spelled out: "d f" is `df`, "p l t" is `plt`.
        // Only a run that started as single letters extends, so "for" plus
        // "x" never becomes "forx".
        var letters: [Unit] = []
        var spelling = false
        for unit in units {
            if case .word(let letter, _) = unit, isLetter(letter),
               case .word(let previous, _)? = letters.last,
               isLetter(previous) || spelling {
                letters[letters.count - 1] = .word(previous + letter, .unknown)
                spelling = true
            } else {
                letters.append(unit)
                spelling = false
            }
        }
        units = letters

        // "importtorch": a keyword the recognizer ran into the module name.
        var split: [Unit] = []
        for unit in units {
            if case .word(let word, _) = unit,
               let keyword = ["import", "from"].first(where: { word.hasPrefix($0) && word.count > $0.count }),
               names.module(String(word.dropFirst(keyword.count))) != nil {
                split.append(.word(keyword, .unknown))
                split.append(.word(String(word.dropFirst(keyword.count)), .unknown))
            } else {
                split.append(unit)
            }
        }
        units = split

        // Resolve each run of words against the table.
        var out: [Unit] = []
        index = 0
        while index < units.count {
            guard case .word(let word, _) = units[index] else {
                out.append(units[index])
                index += 1
                continue
            }
            // "int" is heard as "in" — twice out of twice in "mark equals int
            // input". The keyword `in` can never follow `=`, `(` or a comma, so
            // there it can only be `int`.
            if word == "in", let last = out.last,
               isAssignment(last) || last == .open("(") || last == .comma(hard: true),
               let entry = names.builtin("int") {
                out.append(.word(entry.name, kind(of: entry)))
                index += 1
                continue
            }
            if names.isKeyword(word) || (out.isEmpty && softKeywords.contains(word)) {
                out.append(.word(names.keywordSpelling(word), .keyword))
                index += 1
                continue
            }
            let run = wordRun(units, from: index)
            if out.last == .dot {
                var owner: String?
                if out.count >= 2, case .word(let name, _) = out[out.count - 2] { owner = name }
                if let (entry, used) = names.member(of: owner, words: run) {
                    out.append(.word(entry.name, kind(of: entry)))
                    index += used
                    continue
                }
            } else if case .word(let keyword, .keyword)? = out.last,
                      keyword == "import" || keyword == "from",
                      let entry = names.module(word) {
                out.append(.word(entry.name, .module))
                index += 1
                continue
            }
            if run.count >= 2, let (entry, used) = names.global(words: run) {
                out.append(.word(entry.name, kind(of: entry)))
                index += used
                continue
            }
            if let entry = names.builtin(word) {
                out.append(.word(entry.name, kind(of: entry)))
            } else {
                out.append(.word(word, .unknown))
            }
            index += 1
        }
        // `case if x > 3` is not Python; `case _ if x > 3` is the only
        // reading of it.
        if out.count >= 2, out[0] == .word("case", .keyword), out[1] == .word("if", .keyword) {
            out.insert(.word("_", .unknown), at: 1)
        }
        return joinIdentifiers(out)
    }

    /// Two-letter joins produced so far, so a third letter can extend one
    /// ("p l t") without "do" plus "x" ever becoming "dox".
    private static let lettersJoined: Set<String> = []

    private static func isLetter(_ word: String) -> Bool {
        word.count == 1 && word.first!.isLetter && word.first!.isASCII
    }

    private static func spelling(_ unit: Unit?) -> String? {
        switch unit {
        case .word(let word, _)?: return word
        case .number(let number)?: return number
        default: return nil
        }
    }

    /// Consecutive words starting here, stopping at a keyword or anything else.
    private static func wordRun(_ units: [Unit], from start: Int) -> [String] {
        var words: [String] = []
        var index = start
        while index < units.count, words.count < 4,
              case .word(let word, _) = units[index],
              !PythonNameIndex.shared.isKeyword(word) {
            words.append(word)
            index += 1
        }
        return words
    }

    private static func kind(of entry: PythonNameIndex.Entry) -> Kind {
        if indexers.contains(entry.name) { return .indexer }
        switch entry.kind {
        case .callable: return .callable
        case .type: return .type
        case .attribute: return .attribute
        case .module: return .module
        }
    }

    static let assignments: Set<String> = ["=", "+=", "-=", "*=", "/=", ":="]

    /// Words that are not Python, side by side, become one identifier.
    private static func joinIdentifiers(_ units: [Unit]) -> [Unit] {
        // An assignment target at the start of the line joins whatever it
        // contains: "max value equals" is `max_value =`, not `max(value) =`.
        var targetEnd = 0
        while targetEnd < units.count, case .word(_, let kind) = units[targetEnd], kind != .keyword {
            targetEnd += 1
        }
        if targetEnd < 2 || !(units[safe: targetEnd].map(isAssignment) ?? false) { targetEnd = 0 }

        var out: [Unit] = []
        var index = 0
        while index < units.count {
            guard case .word(let word, let kind) = units[index], kind != .keyword else {
                out.append(units[index])
                index += 1
                continue
            }
            var introducer: String?
            if case .word(let keyword, .keyword)? = out.last { introducer = keyword }
            let naming = introducer == "def" || introducer == "class"
            let target = index < targetEnd

            var run = [word]
            var cursor = index + 1
            while cursor < units.count, case .word(let next, let nextKind) = units[cursor],
                  nextKind != .keyword,
                  naming || target || (isPlain(kind) && isPlain(nextKind)) {
                run.append(next)
                cursor += 1
            }

            if introducer == "class" {
                out.append(.word(run.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(), .unknown))
            } else if run.count > 1 {
                out.append(.word(run.joined(separator: "_"), .unknown))
            } else {
                out.append(naming ? .word(word, .unknown) : units[index])
            }
            index = cursor
        }
        return out
    }

    private static func isPlain(_ kind: Kind) -> Bool {
        kind == .unknown || kind == .attribute
    }

    private static func isAssignment(_ unit: Unit) -> Bool {
        if case .op(let op) = unit { return assignments.contains(op) }
        return false
    }

    // MARK: - Structure: calls, closers, the colon

    private struct Open {
        var mark: String
        var automatic: Bool
        var closer: String { mark == "[" ? "]" : mark == "{" ? "}" : ")" }
    }

    static func structure(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        var stack: [Open] = []
        var first: String?
        if case .word(let word, .keyword)? = units.first { first = word }
        let isBlock = first.map(blockKeywords.contains) ?? false
        let noCalls = first == "import" || first == "from" || first == "except"

        func closeAll() {
            while let open = stack.popLast() { out.append(.close(open.closer)) }
        }

        /// The next unit that is not a pause.
        func meaningful(after index: Int) -> Unit? {
            var cursor = index + 1
            while cursor < units.count, units[cursor] == .comma(hard: false) { cursor += 1 }
            return units[safe: cursor]
        }

        for (index, unit) in units.enumerated() {
            let previous = index > 0 ? units[index - 1] : nil
            switch unit {
            case .word(let word, let kind):
                if word == "as" { closeAll() }
                // Opened for this word's caller: `int(input` wants `input()`.
                let argumentOfCall = out.last == .open("(") && stack.last?.automatic == true
                out.append(unit)
                guard !noCalls, [.callable, .type, .indexer].contains(kind) else { continue }
                if case .word(let keyword, .keyword)? = previous,
                   ["def", "class", "for", "import", "from", "as"].contains(keyword) { continue }
                let next = meaningful(after: index)
                if next == .dot || next == .open("(") || next == .open("[") { continue }
                if let next, isAssignment(next) { continue }

                if startsValue(next) {
                    let mark = kind == .indexer ? "[" : "("
                    out.append(.open(mark))
                    stack.append(Open(mark: mark, automatic: true))
                } else if kind != .indexer, next == nil || isTerminator(next) {
                    // `plt.show()`, `LinearRegression()`: nothing to pass, but
                    // a bare method would be a reference, not a call.
                    if previous == .dot || (kind == .type && previous == .op("="))
                        || (kind == .callable && argumentOfCall) {
                        out.append(.open("("))
                        out.append(.close(")"))
                    }
                }

            case .open(let mark):
                out.append(unit)
                stack.append(Open(mark: mark, automatic: false))

            case .close(let mark):
                if mark.isEmpty {
                    if let open = stack.popLast() { out.append(.close(open.closer)) }
                } else if let match = stack.lastIndex(where: { $0.closer == mark }) {
                    while stack.count > match { out.append(.close(stack.removeLast().closer)) }
                } else {
                    out.append(unit)
                }

            case .comma(let hard):
                if hard || (isValue(out.last) && startsValue(units[safe: index + 1])) {
                    out.append(.comma(hard: true))
                }

            case .colon:
                // The block's colon closes what the line left open — unless
                // the speaker opened a bracket themselves, where a colon is a
                // slice or a dict.
                if isBlock, stack.allSatisfy(\.automatic) { closeAll() }
                out.append(.colon)

            case .dot:
                // `df.groupby("region").mean()`: a dot straight after a string
                // argument is almost always a method on the call's result.
                if case .text? = out.last, stack.last?.automatic == true {
                    out.append(.close(stack.removeLast().closer))
                }
                out.append(unit)

            default:
                out.append(unit)
            }
        }
        closeAll()
        if first == "def", !out.contains(.open("(")), out.count >= 2 {
            out.insert(contentsOf: [.open("("), .close(")")], at: 2)
        }
        if isBlock, out.last != .colon { out.append(.colon) }
        return out
    }

    private static func startsValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word(let word, let kind)?:
            return kind != .keyword || ["not", "lambda", "None", "True", "False"].contains(word)
        case .number?, .text?: return true
        case .open(let mark)?: return mark != "("
        case .op("-")?: return true
        default: return false
        }
    }

    private static func isValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word(_, let kind)?: return kind != .keyword
        case .number?, .text?, .close?: return true
        default: return false
        }
    }

    private static func isTerminator(_ unit: Unit?) -> Bool {
        switch unit {
        case .close?, .comma?, .colon?, .op?, .word(_, .keyword)?: return true
        default: return false
        }
    }

    // MARK: - Rendering

    static func render(_ units: [Unit]) -> String {
        var text = ""
        var opens: [String] = []
        var previous: Unit?
        var unary = false

        for unit in units {
            var piece: String
            var space = previous != nil
            switch unit {
            case .word(let word, _): piece = word
            case .number(let number): piece = number
            case .text(let literal): piece = literal
            case .glue(let mark): piece = mark
            case .capital: continue
            case .dot: piece = "."; space = false
            case .comma: piece = ","; space = false
            case .colon: piece = ":"; space = false
            case .open(let mark):
                piece = mark
                switch previous {
                case .word(_, let kind)?: space = kind == .keyword
                case .close?, .text?: space = false
                default: break
                }
                opens.append(mark)
            case .close(let mark):
                piece = mark
                space = false
                if !opens.isEmpty { opens.removeLast() }
            case .op(let op):
                piece = op
                // Keyword arguments take no spaces: `plot(x, color="red")`.
                if op == "=", opens.last == "(" { space = false }
            }

            switch previous {
            case .open?, .dot?: space = false
            case .op("=")? where opens.last == "(": space = false
            case .colon? where opens.last == "[": space = false
            default: break
            }
            if unary { space = false }
            unary = unit == .op("-") && !isValue(previous)

            if space { text += " " }
            text += piece
            previous = unit
        }
        return text
    }
}

// MARK: - The name table

/// Lookups into `PythonNames`, the table generated from the real libraries.
struct PythonNameIndex: Sendable {
    enum EntryKind: Sendable { case callable, type, attribute, module }

    struct Entry: Sendable {
        let name: String
        let kind: EntryKind
    }

    static let shared = PythonNameIndex(table: PythonNames.table)

    /// Owner label -> squashed name -> entry.
    private let owners: [String: [String: Entry]]
    private let keywords: [String: String]

    init(table: String) {
        var owners: [String: [String: Entry]] = [:]
        var keywords: [String: String] = [:]
        for line in table.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 3 else { continue }
            let owner = String(fields[0])
            let name = String(fields[2])
            if owner == "keyword" {
                keywords[name.lowercased()] = name
                continue
            }
            let kind: EntryKind
            switch fields[1] {
            case "f": kind = .callable
            case "c": kind = .type
            default: kind = owner == "module" ? .module : .attribute
            }
            let key = Self.squash(name)
            // Where two spellings squash together — the class `nn.Linear` and
            // the module `nn.linear` — the one you can call wins.
            if let existing = owners[owner]?[key], Self.rank(existing.kind) <= Self.rank(kind) {
                continue
            }
            owners[owner, default: [:]][key] = Entry(name: name, kind: kind)
        }
        self.owners = owners
        self.keywords = keywords
    }

    private static func rank(_ kind: EntryKind) -> Int {
        switch kind {
        case .type: return 0
        case .callable: return 1
        case .module: return 2
        case .attribute: return 3
        }
    }

    static func squash(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "_", with: "")
    }

    func isKeyword(_ word: String) -> Bool { keywords[word.lowercased()] != nil }

    func keywordSpelling(_ word: String) -> String { keywords[word.lowercased()] ?? word }

    func builtin(_ word: String) -> Entry? { owners["builtins"]?[Self.squash(word)] }

    /// A module name, forgiving one misheard letter: "sklern", "matplotlip".
    func module(_ word: String) -> Entry? {
        guard let modules = owners["module"] else { return nil }
        return Self.lookup(Self.squash(word), in: modules, fuzzy: true)
    }

    /// What people conventionally call these objects, mapped to the table's
    /// owner labels. Knowing the owner is what makes a fuzzy match safe:
    /// "lenspace" after `np.` has one plausible meaning.
    static let conventions: [String: [String]] = [
        "np": ["np"], "numpy": ["np"], "pd": ["pd"], "pandas": ["pd"],
        "df": ["DataFrame", "Series"], "data": ["DataFrame"], "series": ["Series"],
        "plt": ["plt"], "pyplot": ["plt"], "ax": ["Axes"], "fig": ["Figure"],
        "sns": ["sns"], "sklearn": ["sklearn", "module"], "torch": ["torch", "module"],
        "nn": ["nn"], "f": ["F", "file"], "optim": ["optim"], "optimizer": ["model"],
        "model": ["model"], "clf": ["model"], "net": ["model"], "tensor": ["Tensor"],
        "math": ["math"], "random": ["random", "random.np"], "os": ["os", "module"],
        "path": ["os.path", "Path"], "json": ["json"], "csv": ["csv"], "re": ["re"],
        "sys": ["sys"], "datetime": ["datetime"], "time": ["time"],
        "collections": ["collections"], "itertools": ["itertools"],
        "statistics": ["statistics"], "stats": ["scipy.stats"], "scipy": ["module"],
        "file": ["file"], "linalg": ["linalg"], "matplotlib": ["module"],
    ]

    /// Methods of the objects a data script handles, for an owner nobody
    /// recognises. Exact matches only: guessing without knowing the type is
    /// how an ordinary identifier gets rewritten.
    static let anyObject = ["list", "str", "dict", "set", "DataFrame", "Series",
                            "Tensor", "ndarray", "Axes", "Figure", "model", "file", "Path"]

    /// The member a run of words after a dot names, and how many words it took.
    func member(of owner: String?, words: [String]) -> (Entry, Int)? {
        let labels = owner.flatMap { Self.conventions[$0.lowercased()] }
        let scopes = (labels ?? Self.anyObject).compactMap { owners[$0] }
        for length in stride(from: min(3, words.count), through: 1, by: -1) {
            let key = Self.squash(words[0..<length].joined())
            for scope in scopes {
                if let entry = scope[key] { return (entry, length) }
            }
        }
        guard labels != nil else { return nil }
        var merged: [String: Entry] = [:]
        for scope in scopes { merged.merge(scope) { first, _ in first } }
        for length in stride(from: min(2, words.count), through: 1, by: -1) {
            let key = Self.squash(words[0..<length].joined())
            if let entry = Self.lookup(key, in: merged, fuzzy: true) { return (entry, length) }
        }
        return nil
    }

    /// Owners searched for a name spoken as several words anywhere in a line.
    static let globalOwners = [
        "builtins", "module", "model_selection", "preprocessing", "linear_model",
        "metrics", "ensemble", "tree", "cluster", "neighbors", "svm",
        "decomposition", "pipeline", "impute", "pd", "np", "nn", "torch", "plt", "sns",
    ]

    /// A multi-word name: "value error", "train test split", "linear regression".
    func global(words: [String]) -> (Entry, Int)? {
        for length in stride(from: min(4, words.count), through: 2, by: -1) {
            let key = Self.squash(words[0..<length].joined())
            guard key.count >= 6 else { continue }
            for label in Self.globalOwners {
                if let entry = owners[label]?[key] { return (entry, length) }
            }
        }
        return nil
    }

    /// Exact first; otherwise the single closest name within one edit (two for
    /// long names), and nothing at all when two names are equally close.
    private static func lookup(_ key: String, in scope: [String: Entry], fuzzy: Bool) -> Entry? {
        if let exact = scope[key] { return exact }
        guard fuzzy, key.count >= 5 else { return nil }
        let allowed = key.count >= 9 ? 2 : 1
        var best: (entry: Entry, distance: Int)?
        var tied = false
        for (candidate, entry) in scope where abs(candidate.count - key.count) <= allowed {
            let distance = editDistance(key, candidate)
            guard distance <= allowed else { continue }
            if best == nil || distance < best!.distance {
                best = (entry, distance)
                tied = false
            } else if distance == best!.distance {
                tied = true
            }
        }
        return tied ? nil : best?.entry
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }
}
