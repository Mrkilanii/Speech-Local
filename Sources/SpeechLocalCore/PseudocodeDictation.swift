import Foundation

/// Spoken Cambridge pseudocode (IGCSE 0478, A Level 9618) becomes pseudocode.
///
///     "declare mark as integer"                ->  DECLARE Mark : INTEGER
///     "total equals total plus mark"           ->  Total ← Total + Mark
///     "if mark greater than or equal to 70"    ->  IF Mark >= 70 THEN
///     "output quote your grade is close quote comma grade"
///                                              ->  OUTPUT "your grade is", Grade
///     "declare scores array 1 to 10 of integer"
///                                              ->  DECLARE Scores : ARRAY[1:10] OF INTEGER
///
/// The same recognizer, and so the same problems, as `PythonDictation`
/// (decision 10): it writes code as prose, with a capital, pause commas and
/// full stops, and those are stripped everywhere outside a string. What is
/// reused from there is the part that is not about Python — line breaks,
/// dedents, fillers, the glue fixes and the string literal rule. The grammar
/// is this file's own.
///
/// What Cambridge conventions decide:
///
/// * **Keywords upper case, names PascalCase.** "total marks" is `TotalMarks`.
///   Trace Table (the target IDE) matches both keywords and names without
///   regard to case — its lexer upper-cases keywords and its variable store
///   upper-cases names — so the casing is the syllabus's convention, not
///   something a program depends on.
/// * **"equals" is assignment, `←`,** except where an assignment cannot be:
///   in an IF, WHILE or UNTIL condition, a RETURN, or a CASE value, where it
///   is the comparison `=`. "is equal to" is always `=`.
/// * **Block keywords decide the indentation.** A dictation is laid out by
///   `block`, which knows which ENDIF closes which IF.
/// * **THEN and DO are written whether or not they were said**, and anything
///   spoken after them goes on the next line: Cambridge never puts the body of
///   an IF on the IF's own line.
public enum PseudocodeDictation {
    public typealias Line = PythonDictation.Line

    /// The whole dictation as text, for history and the copy panel. Like
    /// `PythonDictation.apply`, unindented: `block` is what is typed.
    public static func apply(to transcript: String) -> String {
        let lines = lines(of: transcript)
        return (lines.first?.breakBefore == true ? "\n" : "")
            + lines.map(\.text).joined(separator: "\n")
    }

    /// Several lines in one press, split where the speaker said "next line".
    /// One spoken line can also become several: "else if" is ELSE and a nested
    /// IF, and a body said after THEN, DO or REPEAT starts a line of its own.
    public static func lines(of transcript: String) -> [Line] {
        let transcript = CodeConfusions.apply(transcript, for: .pseudocode)
        let tokens = PythonDictation.tidyGlue(
            Token.split(transcript).flatMap(splitHyphen)
                .filter { !PythonDictation.fillers.contains(Token.word($0)) })

        var groups: [(tokens: [String], breakBefore: Bool, dedent: Int)] = [([], false, 0)]
        var pending = 0
        var index = 0
        while index < tokens.count {
            if let (_, length) = PythonDictation.phrase(
                tokens, at: index, in: PythonDictation.lineBreaks, longest: 2) {
                // "greater than 100 next. Next line" — a false start on the
                // break. A "next" alone on its line is the FOR loop's NEXT.
                let last = groups[groups.count - 1].tokens
                if last.count > 1, Token.word(last.last ?? "") == "next" {
                    groups[groups.count - 1].tokens.removeLast()
                }
                groups.append(([], true, pending))
                pending = 0
                index += length
                continue
            }
            if let (_, length) = PythonDictation.phrase(
                tokens, at: index, in: PythonDictation.dedents, longest: 2) {
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
        if groups.count > 1, groups[0].tokens.isEmpty { groups.removeFirst() }

        var writer = Writer()
        var out: [Line] = []
        for group in groups {
            let dedent = group.breakBefore ? group.dedent : 0
            for _ in 0..<dedent where !writer.frames.isEmpty { writer.frames.removeLast() }
            let before = writer.lines.count
            writer.statements(lex(opening(group.tokens.flatMap(PythonDictation.unglueQuote))))
            let produced = writer.lines[before...]
            if produced.isEmpty {
                if group.breakBefore {
                    out.append(Line(text: "", breakBefore: true, dedent: dedent))
                }
                continue
            }
            for (offset, text) in produced.enumerated() {
                out.append(offset == 0
                    ? Line(text: text, breakBefore: group.breakBefore, dedent: dedent)
                    : Line(text: text, breakBefore: true, dedent: 0))
            }
        }
        return out
    }

    // MARK: - Layout

    /// The lines as one piece of text, indented here — four spaces a level,
    /// as Trace Table's editor indents (`indentUnit.of('    ')`).
    ///
    /// Depth follows the blocks, not the previous line: ENDIF returns to its
    /// own IF, ELSE to its IF, a CASE value to one level inside its CASE
    /// wherever the branch above left off. OTHERWISE sits with the values, as
    /// the IDE's own indenter puts it. A spoken "step out" is honoured on any
    /// other line.
    public static func block(_ lines: [Line], caretLine: String?) -> String {
        let current = caretLine?.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let leading = current.prefix { $0 == " " || $0 == "\t" }
        var level = leading.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) } / 4
        let caret = current.trimmingCharacters(in: .whitespaces)
        var frames: [(kind: String, level: Int)] = []
        var text = ""
        for (index, line) in lines.enumerated() {
            if line.breakBefore {
                if index == 0, !caret.isEmpty {
                    level = opened(by: caret, at: level, frames: &frames)
                }
                level = placed(line.text, level: level, dedent: line.dedent, frames: &frames)
                text += "\n" + (line.text.isEmpty ? "" : String(repeating: "    ", count: level))
                text += line.text
                level = opened(by: line.text, at: level, frames: &frames)
            } else {
                text += line.text
                let whole = index == 0 ? caret + line.text : line.text
                level = opened(by: whole, at: level, frames: &frames)
            }
        }
        return text
    }

    static let closerOpens: [String: String] = [
        "ENDIF": "IF", "ENDWHILE": "WHILE", "NEXT": "FOR", "UNTIL": "REPEAT",
        "ENDCASE": "CASE", "ENDPROCEDURE": "PROCEDURE", "ENDFUNCTION": "FUNCTION",
        "ENDTYPE": "TYPE", "ENDCLASS": "CLASS",
    ]

    /// The level a new line sits at.
    private static func placed(_ text: String, level: Int, dedent: Int,
                               frames: inout [(kind: String, level: Int)]) -> Int {
        let first = firstWord(text)
        if let opener = closerOpens[first] {
            if let found = frames.lastIndex(where: { $0.kind == opener }) {
                let home = frames[found].level
                frames.removeSubrange(found...)
                return home
            }
            return max(0, level - 1)
        }
        if text == "ELSE" {
            if let found = frames.lastIndex(where: { $0.kind == "IF" }) {
                frames.removeSubrange((found + 1)...)
                return frames[found].level
            }
            return max(0, level - 1)
        }
        // A subroutine inside a loop or an IF is never Cambridge: it was
        // meant to follow it. Out to the enclosing CLASS, or column 0.
        if first == "PROCEDURE" || first == "FUNCTION",
           frames.contains(where: { $0.kind != "CLASS" }) {
            if let owner = frames.lastIndex(where: { $0.kind == "CLASS" }) {
                frames.removeSubrange((owner + 1)...)
                return frames[owner].level + 1
            }
            frames.removeAll()
            return 0
        }
        if isBranch(text), let owner = frames.lastIndex(where: { $0.kind == "CASE" }) {
            frames.removeSubrange((owner + 1)...)
            return frames[owner].level + 1
        }
        let stepped = max(0, level - dedent)
        frames.removeAll { $0.level >= stepped }
        return stepped
    }

    /// The level the line after this one starts at.
    private static func opened(by text: String, at level: Int,
                               frames: inout [(kind: String, level: Int)]) -> Int {
        let first = firstWord(text)
        switch first {
        case "IF" where text.hasSuffix("THEN"), "WHILE" where text.hasSuffix("DO"),
             "FOR", "REPEAT", "PROCEDURE", "FUNCTION", "CLASS":
            frames.append((first, level))
            return level + 1
        case "TYPE" where !text.contains("="):
            frames.append((first, level))
            return level + 1
        case "CASE" where text.hasPrefix("CASE OF"):
            frames.append((first, level))
            return level + 1
        case "ELSE" where text == "ELSE":
            if !frames.contains(where: { $0.kind == "IF" }) { frames.append(("IF", level)) }
            return level + 1
        default:
            guard isBranch(text) else { return level }
            if !frames.contains(where: { $0.kind == "CASE" }) { frames.append(("CASE", level - 1)) }
            // A value with nothing after its colon has its body below it.
            return text == "OTHERWISE" || text.hasSuffix(":") ? level + 1 : level
        }
    }

    /// Words that open a statement, for telling a CASE value from a statement.
    static let statementWords: Set<String> = [
        "DECLARE", "CONSTANT", "INPUT", "OUTPUT", "IF", "THEN", "ELSE", "ENDIF", "CASE",
        "ENDCASE", "FOR", "NEXT", "WHILE", "ENDWHILE", "REPEAT", "UNTIL", "PROCEDURE",
        "ENDPROCEDURE", "FUNCTION", "ENDFUNCTION", "RETURN", "CALL", "OPENFILE", "READFILE",
        "WRITEFILE", "CLOSEFILE", "SEEK", "GETRECORD", "PUTRECORD", "TYPE", "ENDTYPE",
        "CLASS", "ENDCLASS", "DEFINE", "PUBLIC", "PRIVATE",
    ]

    /// `OTHERWISE`, or a CASE value: a line not opened by a statement keyword
    /// with a colon outside its strings and brackets.
    private static func isBranch(_ text: String) -> Bool {
        if text.hasPrefix("OTHERWISE") { return true }
        guard !statementWords.contains(firstWord(text)) else { return false }
        var quote: Character?
        var depth = 0
        for character in text {
            if let open = quote {
                if character == open { quote = nil }
                continue
            }
            switch character {
            case "\"", "'": quote = character
            case "(", "[": depth += 1
            case ")", "]": depth -= 1
            case ":" where depth == 0: return true
            case "/": if text.contains("//") { return false }
            default: break
            }
        }
        return false
    }

    private static func firstWord(_ text: String) -> String {
        String(text.prefix { $0 != " " && $0 != "(" })
    }

    // MARK: - What opens a line

    static let spokenClosers: [String: String] = [
        "if": "endif", "while": "endwhile", "case": "endcase",
        "procedure": "endprocedure", "function": "endfunction", "for": "next",
    ]

    /// Line-start mishearings, from the Python runs of Omar's voice (decision
    /// 10) and the spike: "LF" and "L if" for `elif`, "LS" and "L" for `else`,
    /// "wild" for `while`, "4" for `for`. "and if" is "end if" as the
    /// recognizer tends to write it; no line can open with AND.
    static func opening(_ tokens: [String]) -> [String] {
        guard let first = tokens.first else { return tokens }
        let word = Token.word(first)
        let second = tokens.dropFirst().first.map(Token.word)
        let rest = { (count: Int) in Array(tokens.dropFirst(count)) }

        if ["lf", "elf", "elif"].contains(word) { return ["else", "if"] + rest(1) }
        if ["l", "else", "otherwise"].contains(word), second == "if" {
            return ["else", "if"] + rest(2)
        }
        if ["ls", "els"].contains(word) { return ["else"] + rest(1) }
        if word == "l", second == nil || second == "colon" { return ["else"] + rest(1) }
        if ["and", "end"].contains(word), let second, let closer = spokenClosers[second] {
            return [closer] + rest(2)
        }
        if word == "wild" { return ["while"] + rest(1) }
        if ["declared", "declares"].contains(word) { return ["declare"] + rest(1) }
        // "4 I equals 1 to 10". Only with an assignment before a TO, which a
        // CASE value like "4 to 10" never has.
        if ["4", "four", "fore"].contains(word),
           let to = tokens.firstIndex(where: { Token.word($0) == "to" }),
           tokens[1..<to].contains(where: { ["equals", "from", "gets", "="].contains(Token.word($0)) || $0 == "=" }) {
            return ["for"] + rest(1)
        }
        return tokens
    }

    /// "end-if" is two words to every table here.
    static func splitHyphen(_ token: String) -> [String] {
        let parts = Token.parts(of: token)
        let pieces = parts.core.split(separator: "-")
        guard pieces.count > 1, pieces.allSatisfy({ $0.allSatisfy(\.isLetter) }) else { return [token] }
        var out = pieces.map(String.init)
        out[0] = parts.leading + out[0]
        out[out.count - 1] += parts.trailing
        return out
    }

    // MARK: - Units

    enum Unit: Equatable {
        /// Not yet decided: part of a name, or a word only some lines treat
        /// as a keyword ("to", "of", "do", a type).
        case word(String)
        case keyword(String)
        case builtin(String, spoken: String)
        case name(String)
        case number(String)
        case text(String)
        case op(String)
        case open(String)
        /// An empty closer means "whatever is innermost".
        case close(String)
        /// Soft commas are the recognizer's pauses.
        case comma(hard: Bool)
        case colon
        case dot
        case glue
    }

    static let keywords: [String: String] = [
        "declare": "DECLARE", "constant": "CONSTANT", "input": "INPUT", "output": "OUTPUT",
        "if": "IF", "then": "THEN", "else": "ELSE", "endif": "ENDIF",
        "case": "CASE", "otherwise": "OTHERWISE", "endcase": "ENDCASE",
        "for": "FOR", "next": "NEXT", "while": "WHILE", "endwhile": "ENDWHILE",
        "repeat": "REPEAT", "until": "UNTIL",
        "procedure": "PROCEDURE", "endprocedure": "ENDPROCEDURE",
        "function": "FUNCTION", "endfunction": "ENDFUNCTION",
        "returns": "RETURNS", "returning": "RETURNS", "return": "RETURN", "call": "CALL",
        "and": "AND", "or": "OR", "not": "NOT", "mod": "MOD", "div": "DIV",
        "true": "TRUE", "false": "FALSE",
        "openfile": "OPENFILE", "readfile": "READFILE", "writefile": "WRITEFILE",
        "closefile": "CLOSEFILE", "byref": "BYREF", "byval": "BYVAL",
        "endtype": "ENDTYPE", "endclass": "ENDCLASS",
    ]

    /// The library routines of both syllabuses (Trace Table's `BUILTINS`).
    /// Most are ordinary words too — "year", "left", "round" — so each is a
    /// routine only when a value follows it (`resolve`).
    static let builtinWords: [String: String] = [
        "length": "LENGTH", "len": "LENGTH", "left": "LEFT", "right": "RIGHT", "mid": "MID",
        "substring": "SUBSTRING", "lcase": "LCASE", "ucase": "UCASE", "uppercase": "UCASE",
        "lowercase": "LCASE", "int": "INT", "round": "ROUND", "rand": "RAND",
        "random": "RANDOM", "asc": "ASC", "chr": "CHR", "eof": "EOF", "day": "DAY",
        "month": "MONTH", "year": "YEAR", "dayindex": "DAYINDEX", "setdate": "SETDATE",
        "today": "TODAY",
    ]

    static let arity: [String: Int] = [
        "LENGTH": 1, "LEFT": 2, "RIGHT": 2, "MID": 3, "SUBSTRING": 3, "LCASE": 1, "UCASE": 1,
        "TO_UPPER": 1, "TO_LOWER": 1, "NUM_TO_STR": 1, "STR_TO_NUM": 1, "IS_NUM": 1,
        "ASC": 1, "CHR": 1, "INT": 1, "ROUND": 2, "RAND": 1, "RANDOM": 0, "EOF": 1,
        "DAY": 1, "MONTH": 1, "YEAR": 1, "DAYINDEX": 1, "SETDATE": 3, "TODAY": 0,
    ]

    /// Routines whose one argument is a single value: "length name minus 1"
    /// is `LENGTH(Name) - 1`. `INT` and `ROUND` take arithmetic instead —
    /// "int total divided by 2" is `INT(Total / 2)`.
    static let singleOperand: Set<String> = [
        "LENGTH", "LCASE", "UCASE", "TO_UPPER", "TO_LOWER", "STR_TO_NUM", "IS_NUM", "ASC",
        "CHR", "EOF", "DAY", "MONTH", "YEAR", "DAYINDEX",
    ]

    static let types: [String: String] = [
        "integer": "INTEGER", "integers": "INTEGER", "int": "INTEGER",
        "real": "REAL", "reals": "REAL", "float": "REAL",
        "char": "CHAR", "chars": "CHAR", "character": "CHAR", "characters": "CHAR",
        "string": "STRING", "strings": "STRING", "str": "STRING",
        "boolean": "BOOLEAN", "booleans": "BOOLEAN", "bool": "BOOLEAN",
        "date": "DATE", "dates": "DATE",
    ]

    static let comparisons: Set<String> = ["=", "<>", "<", ">", "<=", ">="]

    /// Spoken commands, matched on bare words, longest first.
    static let phrases: [String: [Unit]] = {
        var table: [String: [Unit]] = [:]
        func add(_ unit: Unit, _ spoken: String...) {
            for phrase in spoken { table[phrase] = [unit] }
        }
        add(.op("←"), "equals", "equal", "is equals", "equal sign", "equals sign", "gets",
            "becomes", "is assigned", "is assigned to", "assign", "assigned", "assigned to",
            "left arrow", "arrow")
        add(.op("="), "is equal to", "equal to", "equals to", "is equal", "double equals",
            "equals equals", "double equal", "is the same as")
        add(.op("<>"), "not equal to", "not equals", "not equal", "is not equal to",
            "is not equals", "is not equal", "does not equal", "doesn't equal",
            "isn't equal to", "not equals to")
        // "or" is heard as "are", "your", or dropped (decision 10).
        for (words, mark) in [("greater than", ">"), ("less than", "<"), ("more than", ">"),
                              ("bigger than", ">"), ("smaller than", "<"), ("fewer than", "<")] {
            for lead in ["", "is "] {
                add(.op(mark), lead + words)
                for tail in [" or equal to", " or equals", " or equal", " are equal to",
                             " are equal", " your equal to", " you're equal to",
                             " equal to", " equals"] {
                    add(.op(mark + "="), lead + words + tail)
                }
            }
        }
        add(.op(">="), "at least", "is at least")
        add(.op("<="), "at most", "is at most")
        add(.op("+"), "plus")
        add(.op("-"), "minus", "negative")
        add(.op("*"), "times", "multiplied by", "multiply by")
        add(.op("/"), "divided by", "divide by")
        add(.op("^"), "to the power of", "to the power", "raised to", "raised to the power of")
        add(.op("&"), "ampersand", "concatenated with", "concatenate", "joined with", "joined to")
        add(.keyword("MOD"), "modulo", "modulus")
        add(.keyword("DIV"), "integer divide", "integer divided by", "integer division",
            "floor divide", "floor divided by")

        add(.open("("), "open bracket", "open brackets", "open paren", "open parenthesis",
            "open round bracket", "left bracket", "left paren", "paren", "taking")
        add(.close(")"), "close bracket", "closed bracket", "close brackets", "close paren",
            "closed paren", "close parenthesis", "right bracket", "right paren")
        add(.open("["), "open square", "open square bracket", "square brackets",
            "square bracket", "left square")
        add(.close("]"), "close square", "closed square", "close square bracket",
            "close square brackets", "closed square bracket")
        for phrase in PythonDictation.outsidePhrases { table[phrase] = [.close("")] }
        add(.close(""), "close", "closed")
        add(.comma(hard: true), "comma")
        add(.colon, "colon")
        add(.dot, "dot")
        add(.glue, "underscore")

        add(.keyword("ENDIF"), "end if", "end of if")
        add(.keyword("ENDWHILE"), "end while", "end of while")
        add(.keyword("ENDCASE"), "end case", "end of case")
        add(.keyword("ENDPROCEDURE"), "end procedure", "end of procedure", "end proc")
        add(.keyword("ENDFUNCTION"), "end function", "end of function")
        add(.keyword("ENDTYPE"), "end type")
        add(.keyword("ENDCLASS"), "end class")
        add(.keyword("CASE"), "case of", "case off", "cases of")
        table["else if"] = [.keyword("ELSE"), .keyword("IF")]
        add(.keyword("OPENFILE"), "open file")
        add(.keyword("READFILE"), "read file")
        add(.keyword("WRITEFILE"), "write file")
        add(.keyword("CLOSEFILE"), "close file")
        add(.keyword("BYREF"), "by ref", "by reference")
        add(.keyword("BYVAL"), "by val", "by value")

        for (spoken, name) in [("to upper case", "TO_UPPER"), ("to uppercase", "TO_UPPER"),
                               ("to lower case", "TO_LOWER"), ("to lowercase", "TO_LOWER"),
                               ("upper case", "UCASE"), ("lower case", "LCASE"),
                               ("u case", "UCASE"), ("l case", "LCASE"),
                               ("num to str", "NUM_TO_STR"), ("number to string", "NUM_TO_STR"),
                               ("str to num", "STR_TO_NUM"), ("string to number", "STR_TO_NUM"),
                               ("is num", "IS_NUM"), ("is numeric", "IS_NUM"),
                               ("end of file", "EOF"), ("day index", "DAYINDEX"),
                               ("set date", "SETDATE"), ("sub string", "SUBSTRING")] {
            table[spoken] = [.builtin(name, spoken: spoken)]
        }
        return table
    }()

    static let phraseKeys = Set(phrases.keys)
    static let longestPhrase = phrases.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// What opens a string. "speech marks" is how British classrooms say it.
    static let stringOpeners: [String: String] = [
        "quote": "\"", "quotes": "\"", "quotation mark": "\"", "quotation marks": "\"",
        "double quote": "\"", "double quotes": "\"", "open quote": "\"", "open quotes": "\"",
        "speech mark": "\"", "speech marks": "\"", "inverted commas": "\"",
        "single quote": "'", "single quotes": "'",
    ]
    static let stringOpenerKeys = Set(stringOpeners.keys)
    static let stringClosers = PythonDictation.stringClosers
        .union(["speech mark", "speech marks", "close speech marks", "end speech marks",
                "inverted commas", "close single quote"])

    // MARK: - Lexing

    /// A string runs to "close quote" or to the end of the line, exactly as in
    /// Python; everything else is code.
    static func lex(_ tokens: [String]) -> [Unit] {
        var units: [Unit] = []
        var code: [String] = []
        func flush() {
            guard !code.isEmpty else { return }
            units.append(contentsOf: lexCode(SpokenNumbers.apply(to: code)))
            code = []
        }
        var index = 0
        while index < tokens.count {
            let word = Token.word(tokens[index])
            if ["close", "closed", "end"].contains(word),
               let next = tokens[safe: index + 1], ["quote", "quotes"].contains(Token.word(next)) {
                index += 2
                continue
            }
            guard let (opener, length) = PythonDictation.phrase(
                tokens, at: index, in: stringOpenerKeys, longest: 2) else {
                code.append(tokens[index])
                index += 1
                continue
            }
            flush()
            var cursor = index + length
            var content: [String] = []
            var closed = false
            var leavesBracket = false
            while cursor < tokens.count {
                if let (closer, length) = PythonDictation.phrase(
                    tokens, at: cursor, in: stringClosers, longest: 6) {
                    cursor += length
                    closed = true
                    leavesBracket = closer.hasPrefix("outside")
                    break
                }
                content.append(tokens[cursor])
                cursor += 1
            }
            units.append(.text(PythonDictation.literal(
                content, opener: stringOpeners[opener]!, closed: closed)))
            if leavesBracket { units.append(.close("")) }
            if closed, Token.parts(of: tokens[cursor - 1]).trailing.contains(",") {
                units.append(.comma(hard: false))
            }
            index = cursor
        }
        flush()
        return units
    }

    private static func lexCode(_ tokens: [String]) -> [Unit] {
        var units: [Unit] = []
        var index = 0
        while index < tokens.count {
            if let (phrase, length) = PythonDictation.phrase(
                tokens, at: index, in: phraseKeys, longest: longestPhrase) {
                units.append(contentsOf: phrases[phrase]!)
                index += length
                units.append(contentsOf: trailing(tokens[index - 1], next: tokens[safe: index],
                                                  command: true))
                continue
            }
            // "0 point 2" — a decimal said aloud.
            let core = Token.parts(of: tokens[index]).core
            if core.lowercased() == "point", case .number(let whole)? = units.last,
               !whole.contains("."), let next = tokens[safe: index + 1] {
                let digits = Token.parts(of: next).core
                if !digits.isEmpty, digits.allSatisfy(\.isNumber) {
                    units[units.count - 1] = .number(whole + "." + digits)
                    units.append(contentsOf: trailing(next, next: tokens[safe: index + 2],
                                                      command: false))
                    index += 2
                    continue
                }
            }
            units.append(contentsOf: tokenUnits(tokens[index], next: tokens[safe: index + 1]))
            index += 1
        }
        return units
    }

    /// Symbols the recognizer sometimes writes itself. A lone "=" is how it
    /// writes "equals", which is assignment until a condition says otherwise.
    static let symbols: [String: Unit] = [
        "=": .op("←"), "==": .op("="), "!=": .op("<>"), "<>": .op("<>"), "<": .op("<"),
        ">": .op(">"), "<=": .op("<="), ">=": .op(">="), "+": .op("+"), "-": .op("-"),
        "*": .op("*"), "/": .op("/"), "^": .op("^"), "&": .op("&"), "←": .op("←"),
        "<-": .op("←"),
    ]

    private static func tokenUnits(_ token: String, next: String?) -> [Unit] {
        let parts = Token.parts(of: token)
        if parts.core.isEmpty {
            let symbol = parts.leading + parts.trailing
            if let unit = symbols[symbol] { return [unit] }
            return symbol.compactMap(bracket)
        }
        var units: [Unit] = []
        for character in parts.leading {
            if let unit = bracket(character) {
                units.append(unit)
            } else if character == "-" {
                units.append(.op("-"))
            }
        }
        let core = parts.core
        if isDecimal(core) {
            units.append(.number(core))
        } else {
            for (position, piece) in core.split(separator: ":", omittingEmptySubsequences: false)
                .enumerated() {
                if position > 0 { units.append(.colon) }
                for (place, part) in piece.split(separator: ".", omittingEmptySubsequences: false)
                    .enumerated() {
                    if place > 0 { units.append(.dot) }
                    guard !part.isEmpty else { continue }
                    units.append(wordUnit(String(part)))
                }
            }
        }
        units.append(contentsOf: trailing(token, next: next, command: false))
        return units
    }

    private static func wordUnit(_ word: String) -> Unit {
        if word.allSatisfy(\.isNumber) { return .number(word) }
        let lower = word.lowercased()
        if let keyword = keywords[lower] { return .keyword(keyword) }
        if let builtin = builtinWords[lower] { return .builtin(builtin, spoken: lower) }
        return .word(word)
    }

    private static func isDecimal(_ text: String) -> Bool {
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        return pieces.count == 2 && pieces.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }

    private static func bracket(_ character: Character) -> Unit? {
        switch character {
        case "(", "[": return .open(String(character))
        case ")", "]": return .close(String(character))
        default: return nil
        }
    }

    /// The punctuation hanging off a token: mostly the recognizer's prose. A
    /// comma between two figures was spoken; a full stop is a dot only
    /// between two names ("pupil. name" is a record field).
    private static func trailing(_ token: String, next: String?, command: Bool) -> [Unit] {
        let parts = Token.parts(of: token)
        let isFigure = !parts.core.isEmpty && parts.core.allSatisfy(\.isNumber)
            && next.map(SpokenNumbers.isFigure) == true
        var units: [Unit] = []
        for character in parts.trailing {
            switch character {
            case ",": units.append(.comma(hard: isFigure && !command))
            case ":": units.append(.colon)
            case ")", "]": units.append(.close(String(character)))
            case ".":
                if parts.trailing == ".", !command, !parts.core.allSatisfy(\.isNumber),
                   let next, next.first?.isLowercase == true,
                   keywords[Token.word(next)] == nil, !phraseKeys.contains(Token.word(next)) {
                    units.append(.dot)
                }
            default: break
            }
        }
        return units
    }

    // MARK: - Statements

    enum Frame: Equatable {
        case ifBlock, caseBlock, forLoop(String), whileLoop, repeatLoop, procedure, function
    }

    static let statementStarts: Set<String> = [
        "OUTPUT", "INPUT", "CALL", "RETURN", "DECLARE", "CONSTANT",
        "OPENFILE", "READFILE", "WRITEFILE", "CLOSEFILE",
    ]

    /// Keywords that can only begin a line: said mid-line, a new line starts.
    static let lineStarters: Set<String> = [
        "ELSE", "OTHERWISE", "ENDIF", "ENDWHILE", "ENDCASE", "ENDPROCEDURE", "ENDFUNCTION",
        "ENDTYPE", "ENDCLASS", "UNTIL", "REPEAT",
    ]

    /// Writes lines in order, and keeps the blocks they open, so that a later
    /// line can be read in context: OTHERWISE in an IF is ELSE, a bare NEXT
    /// names its loop's variable, a line inside a CASE is a value.
    struct Writer {
        var lines: [String] = []
        var frames: [Frame] = []

        mutating func emit(_ text: String) {
            lines.append(text)
            let words = text.split(separator: " ").map(String.init)
            switch words.first ?? "" {
            case "IF": frames.append(.ifBlock)
            case "CASE": frames.append(.caseBlock)
            case "FOR": frames.append(.forLoop(words[safe: 1] ?? ""))
            case "WHILE": frames.append(.whileLoop)
            case "REPEAT": frames.append(.repeatLoop)
            case "PROCEDURE": frames.append(.procedure)
            case "FUNCTION": frames.append(.function)
            case "ENDIF": pop { $0 == .ifBlock }
            case "ENDCASE": pop { $0 == .caseBlock }
            case "NEXT": pop { if case .forLoop = $0 { return true } else { return false } }
            case "ENDWHILE": pop { $0 == .whileLoop }
            case "UNTIL": pop { $0 == .repeatLoop }
            case "ENDPROCEDURE": pop { $0 == .procedure }
            case "ENDFUNCTION": pop { $0 == .function }
            default: break
            }
        }

        private mutating func pop(_ matches: (Frame) -> Bool) {
            if let found = frames.lastIndex(where: matches) { frames.removeSubrange(found...) }
        }

        /// The innermost IF or CASE.
        var selection: Frame? {
            frames.last { $0 == .ifBlock || $0 == .caseBlock }
        }

        mutating func statements(_ units: [Unit]) {
            var piece: [Unit] = []
            for unit in units {
                if case .keyword(let keyword) = unit, lineStarters.contains(keyword), !piece.isEmpty {
                    statement(piece)
                    piece = []
                }
                piece.append(unit)
            }
            statement(piece)
        }

        mutating func statement(_ spoken: [Unit]) {
            let units = PD.trim(spoken)
            guard let first = units.first else { return }
            let rest = Array(units.dropFirst())

            // "end" on its own closes whatever is open.
            if units.count == 1, PD.bare(first) == "end", let open = frames.last {
                switch open {
                case .ifBlock: emit("ENDIF")
                case .caseBlock: emit("ENDCASE")
                case .forLoop(let variable): emit(variable.isEmpty ? "NEXT" : "NEXT " + variable)
                case .whileLoop: emit("ENDWHILE")
                case .repeatLoop: emit("UNTIL")
                case .procedure: emit("ENDPROCEDURE")
                case .function: emit("ENDFUNCTION")
                }
                return
            }

            // "print" is the Python habit, and the old syllabus's word;
            // OUTPUT is today's. Only where a statement starts: "print
            // total" can still name a procedure.
            if PD.bare(first) == "print" { return statement([.keyword("OUTPUT")] + rest) }
            // THEN or DO said on the line after its header: already written.
            if first == .keyword("THEN") || PD.bare(first) == "do" { return statements(rest) }
            guard case .keyword(var keyword) = first else { return plain(units) }
            // "next value equals 5" is a name, not the end of a loop.
            if keyword == "NEXT", rest.contains(.op("←")) {
                return plain([.word("next")] + rest)
            }
            // Cambridge has no ELSE in a CASE and no OTHERWISE in an IF;
            // whichever is said, the block it is in decides.
            if keyword == "ELSE", selection == .caseBlock { keyword = "OTHERWISE" }
            if keyword == "OTHERWISE", selection == .ifBlock { keyword = "ELSE" }

            switch keyword {
            case "ELSE":
                emit("ELSE")
                statements(PD.trimColons(rest))
            case "OTHERWISE":
                labelled("OTHERWISE :", empty: "OTHERWISE", PD.trimColons(rest))
            case "IF":
                header("IF", "THEN", rest) { $0.first == .keyword("THEN") }
            case "WHILE":
                header("WHILE", "DO", rest) { PD.bare($0.first) == "do" }
            case "UNTIL":
                emit("UNTIL " + PD.expr(PD.trimColons(rest), condition: true))
            case "REPEAT":
                emit("REPEAT")
                statements(PD.trimColons(rest))
            case "FOR":
                forLoop(rest)
            case "NEXT":
                let named = PD.trim(rest)
                if named.isEmpty, case .forLoop(let variable)? = frames.last(where: {
                    if case .forLoop = $0 { return true } else { return false }
                }), !variable.isEmpty {
                    emit("NEXT " + variable)
                } else {
                    emit(named.isEmpty ? "NEXT" : "NEXT " + PD.expr(named))
                }
            case "CASE":
                var subject = PD.trimColons(rest)
                if let of = PD.bare(subject.first), ["of", "off"].contains(of) {
                    subject.removeFirst()
                }
                emit(subject.isEmpty ? "CASE OF" : "CASE OF " + PD.expr(PD.trimColons(subject)))
            case "DECLARE":
                emit(PD.declaration(rest))
            case "CONSTANT":
                let body = PD.trimColons(rest)
                if let at = body.firstIndex(where: { $0 == .op("←") || $0 == .op("=") }),
                   case .op(let mark) = body[at] {
                    emit("CONSTANT " + PD.expr(Array(body[..<at])) + " " + mark + " "
                         + PD.expr(Array(body[(at + 1)...])))
                } else {
                    emit("CONSTANT " + PD.expr(body))
                }
            case "PROCEDURE", "FUNCTION":
                emit(PD.subroutine(keyword, rest))
            case "CALL":
                emit(PD.call(rest))
            case "RETURN":
                let value = PD.expr(rest, condition: true)
                emit(value.isEmpty ? "RETURN" : "RETURN " + value)
            case "INPUT":
                input(prompt: [], target: rest)
            case "OUTPUT":
                // Nothing is assigned in an OUTPUT: "output x equals y"
                // prints the comparison.
                emit("OUTPUT " + PD.expr(rest, condition: true, list: true))
            case "OPENFILE":
                let body = PD.trim(rest)
                if let at = body.firstIndex(of: .keyword("FOR")) {
                    emit("OPENFILE " + PD.expr(Array(body[..<at])) + " FOR "
                         + PD.fileMode(Array(body[(at + 1)...])))
                } else {
                    emit("OPENFILE " + PD.expr(body))
                }
            case "READFILE", "WRITEFILE":
                emit(keyword + " " + PD.expr(rest, list: true))
            case "CLOSEFILE":
                emit("CLOSEFILE " + PD.expr(rest))
            case "ENDIF", "ENDWHILE", "ENDCASE", "ENDPROCEDURE", "ENDFUNCTION", "ENDTYPE",
                 "ENDCLASS":
                emit(keyword)
                statements(PD.trimColons(rest))
            default:
                plain(units)
            }
        }

        /// IF and WHILE: a condition, the closing word whether said or not,
        /// and anything said after it on a line of its own.
        private mutating func header(_ keyword: String, _ closer: String, _ rest: [Unit],
                                     isCloser: ([Unit]) -> Bool) {
            var condition = rest
            var body: [Unit] = []
            if let at = rest.indices.first(where: { isCloser(Array(rest[$0...])) }) {
                condition = Array(rest[..<at])
                body = Array(rest[(at + 1)...])
            } else if let at = rest.indices.dropFirst().first(where: { PD.startsStatement(rest[$0]) }) {
                condition = Array(rest[..<at])
                body = Array(rest[at...])
            } else if let at = PD.assignmentTarget(in: rest) {
                // "while x less than 10 x equals x plus 1": the body is an
                // assignment, and its target starts after the last value.
                condition = Array(rest[..<at])
                body = Array(rest[at...])
            }
            emit(keyword + " " + PD.expr(PD.trimColons(condition), condition: true) + " " + closer)
            statements(PD.trimColons(body))
        }

        private mutating func forLoop(_ rest: [Unit]) {
            var range = PD.trimColons(rest)
            var body: [Unit] = []
            if let at = range.indices.dropFirst().first(where: { PD.startsStatement(range[$0]) }) {
                body = Array(range[at...])
                range = PD.trimColons(Array(range[..<at]))
            }
            let assign = range.firstIndex { $0 == .op("←") || $0 == .op("=") || PD.bare($0) == "from" }
            var variable: [Unit]
            var bounds: [Unit]
            if let assign {
                variable = Array(range[..<assign])
                bounds = Array(range[(assign + 1)...])
            } else {
                // "for i 1 to 10": the loop variable runs up to the first figure.
                let start = range.firstIndex { if case .number = $0 { return true } else { return false } }
                    ?? range.firstIndex { PD.bare($0) == "to" } ?? range.count
                variable = Array(range[..<start])
                bounds = Array(range[start...])
            }
            var step: [Unit] = []
            if let at = bounds.firstIndex(where: { PD.bare($0) == "step" }) {
                step = Array(bounds[(at + 1)...])
                bounds = Array(bounds[..<at])
            }
            var end: [Unit] = []
            if let at = bounds.firstIndex(where: { PD.bare($0) == "to" }) {
                end = Array(bounds[(at + 1)...])
                bounds = Array(bounds[..<at])
            }
            variable = PD.trim(variable)
            var text = "FOR " + PD.expr(variable)
            if !bounds.isEmpty || !end.isEmpty { text += " ← " + PD.expr(bounds) }
            if !end.isEmpty { text += " TO " + PD.expr(end) }
            if !step.isEmpty { text += " STEP " + PD.expr(step) }
            emit(text)
            statements(body)
        }

        /// A line that does not open with a keyword: a CASE value, an
        /// assignment, or an expression.
        private mutating func plain(_ units: [Unit]) {
            let assign = units.firstIndex(of: .op("←"))
            let colon = units.firstIndex(of: .colon)
            let colonFirst = colon.map { colon in assign.map { colon < $0 } ?? true } ?? false
            let startsWithValue: Bool = {
                switch units.first {
                case .number?, .text?, .op("-")?, .keyword("TRUE")?, .keyword("FALSE")?: return true
                default: return false
                }
            }()
            let statementLater = units.dropFirst().contains(where: PD.startsStatement)
            let isValue = colonFirst
                || (selection == .caseBlock && assign == nil)
                || (startsWithValue && statementLater && assign == nil)
            if isValue {
                let split = colon ?? units.indices.dropFirst().first { PD.startsStatement(units[$0]) }
                    ?? units.count
                let value = units[..<split].map { PD.bare($0) == "to" ? .keyword("TO") : $0 }
                let label = PD.expr(PD.trim(value), condition: true) + " :"
                labelled(label, empty: label, PD.trimColons(Array(units[split...])))
                return
            }
            if let assign {
                var value = PD.trim(Array(units[(assign + 1)...]))
                // "mark equals int input", "Mark equals in input": Python's
                // spelling of INPUT, and in Cambridge INPUT is a statement.
                if value.count > 1, value[1] == .keyword("INPUT") {
                    let lead = value[0]
                    if PD.bare(lead) == "in" { value.removeFirst() }
                    if case .builtin("INT", _) = lead { value.removeFirst() }
                }
                if value.first == .keyword("INPUT") {
                    return input(prompt: Array(value.dropFirst()), target: Array(units[..<assign]))
                }
                emit(PD.expr(Array(units[..<assign])) + " ← " + PD.expr(value))
                return
            }
            emit(PD.expr(units))
        }

        /// INPUT takes no prompt in Cambridge: a prompt said with it is an
        /// OUTPUT on the line before.
        private mutating func input(prompt: [Unit], target: [Unit]) {
            var prompt = PD.trim(prompt)
            var target = PD.trim(target)
            if prompt.isEmpty, case .text? = target.first, target.count > 1 {
                prompt = [target.removeFirst()]
                target = PD.trim(target)
            }
            if !prompt.isEmpty { emit("OUTPUT " + PD.expr(prompt, list: true)) }
            let name = PD.expr(target)
            emit(name.isEmpty ? "INPUT" : "INPUT " + name)
        }

        /// "70 :" or "OTHERWISE :" followed by the first line of what was said
        /// after it; any further lines follow on their own.
        private mutating func labelled(_ prefix: String, empty: String, _ body: [Unit]) {
            var sub = Writer()
            sub.frames = frames
            sub.statements(body)
            if let head = sub.lines.first {
                lines.append(prefix + " " + head)
                lines.append(contentsOf: sub.lines.dropFirst())
                frames = sub.frames
            } else {
                lines.append(empty)
            }
            // A value or OTHERWISE outside any known CASE: the CASE opened in
            // an earlier press, and later lines of this one are its values.
            if !frames.contains(.caseBlock) { frames.append(.caseBlock) }
        }
    }

    // MARK: - Declarations and headers

    /// "declare mark integer", "declare mark as integer", "declare mark colon
    /// integer": `DECLARE Mark : INTEGER`.
    static func declaration(_ rest: [Unit]) -> String {
        let units = trimColons(rest)
        let split = units.firstIndex { unit in
            unit == .colon || bare(unit) == "as" || bare(unit) == "array" || typeWord(unit) != nil
        } ?? units.count
        let name = expr(Array(units[..<split]), list: true)
        var kind = Array(units[split...])
        while let first = kind.first, first == .colon || bare(first) == "as" { kind.removeFirst() }
        let type = typeName(kind)
        return "DECLARE " + name + (type.isEmpty ? "" : " : " + type)
    }

    /// A type, spoken: INTEGER, an ARRAY, or a type of the program's own.
    static func typeName(_ input: [Unit]) -> String {
        var units = trimColons(input)
        while let first = bare(units.first), ["a", "an"].contains(first) { units.removeFirst() }
        guard let first = units.first else { return "" }
        if units.count == 1, let type = typeWord(first) { return type }
        if bare(first) == "array" { return arrayType(Array(units.dropFirst())) }
        return expr(units)
    }

    static func typeWord(_ unit: Unit) -> String? {
        switch unit {
        case .word(let word): return types[word.lowercased()]
        case .builtin("INT", _): return "INTEGER"
        default: return nil
        }
    }

    /// "array 1 to 10 of integer", "array 1 to 3 comma 1 to 3 of char",
    /// "array of 10 strings". Cambridge arrays count from 1, so a bare size
    /// is `1:size`.
    static func arrayType(_ input: [Unit]) -> String {
        let units = input.filter { ![.open("["), .close("]"), .close("")].contains($0) }
        let of = units.lastIndex { bare($0) == "of" }
        var bounds = of.map { Array(units[..<$0]) } ?? units
        var element = of.map { Array(units[($0 + 1)...]) } ?? []
        if trim(bounds).isEmpty, element.count >= 2, case .number = element[0] {
            bounds = [element[0]]
            element = Array(element.dropFirst())
        }
        var dimensions: [String] = []
        var dimension: [Unit] = []
        for unit in trim(bounds) + [.comma(hard: true)] {
            if case .comma = unit {
                let parts = trim(dimension)
                dimension = []
                guard !parts.isEmpty else { continue }
                if let at = parts.firstIndex(where: { $0 == .colon || ["to", "through"].contains(bare($0) ?? "") }) {
                    dimensions.append(expr(Array(parts[..<at])) + ":" + expr(Array(parts[(at + 1)...])))
                } else {
                    dimensions.append("1:" + expr(parts))
                }
                continue
            }
            dimension.append(unit)
        }
        let type = typeName(element)
        // A parameter's array has no bounds: `Marks : ARRAY OF INTEGER`.
        let shape = dimensions.isEmpty ? "ARRAY" : "ARRAY[" + dimensions.joined(separator: ", ") + "]"
        return shape + (type.isEmpty ? "" : " OF " + type)
    }

    static let parameterIntroducers: Set<String> = [
        "with", "using", "passing", "parameter", "parameters", "takes", "accepting",
    ]

    /// "function square taking number colon integer returns integer":
    /// `FUNCTION Square(Number : INTEGER) RETURNS INTEGER`.
    static func subroutine(_ keyword: String, _ rest: [Unit]) -> String {
        var head = trimColons(rest)
        var returns: [Unit] = []
        if let at = head.firstIndex(of: .keyword("RETURNS")) {
            returns = Array(head[(at + 1)...])
            head = Array(head[..<at])
        }
        var name = head
        var parameters: [Unit] = []
        if let at = head.firstIndex(where: {
            $0 == .open("(") || parameterIntroducers.contains(bare($0) ?? "")
        }) {
            name = Array(head[..<at])
            parameters = Array(head[(at + 1)...])
        } else if let at = head.firstIndex(where: { $0 == .colon || bare($0) == "as" || typeWord($0) != nil }),
                  at >= 2 {
            // No word to say where the name ends: the name is one word.
            name = [head[0]]
            parameters = Array(head[1...])
        }
        while let first = bare(parameters.first), parameterIntroducers.contains(first) {
            parameters.removeFirst()
        }
        var text = keyword + " " + expr(nameOnly(name))
        let list = parameterList(parameters)
        if !list.isEmpty { text += "(" + list.joined(separator: ", ") + ")" }
        let type = typeName(returns)
        if !type.isEmpty { text += " RETURNS " + type }
        return text
    }

    /// "x colon integer comma y as integer", "x integer and y integer".
    static func parameterList(_ input: [Unit]) -> [String] {
        let units = input.filter {
            if case .open = $0 { return false }
            if case .close = $0 { return false }
            return true
        }
        var groups: [[Unit]] = [[]]
        for unit in units {
            // A pause comma ends a parameter only once it has its type:
            // "taking marks, colon, integer" is one parameter.
            if case .comma(let hard) = unit, hard || hasType(groups[groups.count - 1]) {
                groups.append([])
            } else if case .comma = unit {
                continue
            } else if unit == .keyword("AND") {
                groups.append([])
            } else {
                groups[groups.count - 1].append(unit)
            }
        }
        return groups.compactMap { group -> String? in
            var group = trimColons(group)
            guard !group.isEmpty else { return nil }
            var mode = ""
            if case .keyword(let keyword) = group[0], keyword == "BYREF" || keyword == "BYVAL" {
                mode = keyword + " "
                group.removeFirst()
            }
            let split = group.indices.first { index in
                group[index] == .colon || bare(group[index]) == "as"
                    || (index > 0 && typeWord(group[index]) != nil)
            } ?? group.count
            var kind = Array(group[split...])
            while let first = kind.first, first == .colon || bare(first) == "as" { kind.removeFirst() }
            let type = typeName(kind)
            return mode + expr(Array(group[..<split])) + (type.isEmpty ? "" : " : " + type)
        }
    }

    /// A name followed by its type, or by a colon or "as" with something after it.
    private static func hasType(_ group: [Unit]) -> Bool {
        if group.dropFirst().contains(where: { typeWord($0) != nil }) { return true }
        guard let marker = group.firstIndex(where: { $0 == .colon || bare($0) == "as" }) else {
            return false
        }
        return group.index(after: marker) < group.endIndex
    }

    /// "call greet", "call greet taking name", "call show with total".
    static func call(_ rest: [Unit]) -> String {
        let units = trimColons(rest)
        guard let at = units.firstIndex(where: {
            $0 == .open("(") || ["with", "using", "passing"].contains(bare($0) ?? "")
        }) else {
            return "CALL " + expr(nameOnly(units))
        }
        var arguments = Array(units[(at + 1)...])
        while let last = arguments.last, case .close = last { arguments.removeLast() }
        return "CALL " + expr(nameOnly(Array(units[..<at]))) + "(" + expr(arguments, list: true) + ")"
    }

    static func fileMode(_ units: [Unit]) -> String {
        let modes = ["read": "READ", "reading": "READ", "write": "WRITE", "writing": "WRITE",
                     "append": "APPEND", "appending": "APPEND", "random": "RANDOM"]
        switch trim(units).first {
        case .builtin(_, let spoken)?: return modes[spoken] ?? spoken.uppercased()
        case let unit?: return bare(unit).flatMap { modes[$0] } ?? expr([unit])
        case nil: return ""
        }
    }

    static func startsStatement(_ unit: Unit) -> Bool {
        if case .keyword(let keyword) = unit { return statementStarts.contains(keyword) }
        return bare(unit) == "print"
    }

    /// Where an assignment said inside a header begins: the name before its
    /// `←`, when a value that cannot be part of the name comes just before
    /// it. "if a greater than b c equals 1" has no such boundary, and stays
    /// one line.
    static func assignmentTarget(in units: [Unit]) -> Int? {
        guard let arrow = units.firstIndex(of: .op("←")) else { return nil }
        var start = arrow
        var depth = 0
        while start > 0 {
            let unit = units[start - 1]
            if unit == .close("]") {
                depth += 1
            } else if unit == .open("[") {
                depth -= 1
            } else if depth == 0, !(isWordUnit(unit) || unit == .dot || unit == .glue) {
                break
            }
            start -= 1
        }
        guard start > 0, start < arrow, depth == 0 else { return nil }
        switch units[start - 1] {
        case .number, .text, .close, .keyword("TRUE"), .keyword("FALSE"): return start
        default: return nil
        }
    }

    private static func isWordUnit(_ unit: Unit) -> Bool {
        if case .word = unit { return true }
        return false
    }

    /// A subroutine's name, in which keywords are just words: "procedure
    /// input marks" is `InputMarks`.
    static func nameOnly(_ units: [Unit]) -> [Unit] {
        units.map { unit in
            if case .keyword(let keyword) = unit { return .word(keyword.lowercased()) }
            return unit
        }
    }

    // MARK: - Expressions

    static func bare(_ unit: Unit?) -> String? {
        if case .word(let word)? = unit { return word.lowercased() }
        return nil
    }

    /// Without the pause commas at either end.
    static func trim(_ units: [Unit]) -> [Unit] {
        var units = units
        while let first = units.first, case .comma = first { units.removeFirst() }
        while let last = units.last, case .comma = last { units.removeLast() }
        return units
    }

    /// Without commas or colons at either end: a header's colon is Python.
    static func trimColons(_ units: [Unit]) -> [Unit] {
        var units = units
        while let first = units.first, first == .colon || isComma(first) { units.removeFirst() }
        while let last = units.last, last == .colon || isComma(last) { units.removeLast() }
        return units
    }

    /// An expression: names joined in PascalCase, routines called, brackets
    /// closed. `condition` reads "equals" and "is" as `=`; `list` keeps the
    /// commas between values, as OUTPUT and argument lists need.
    static func expr(_ input: [Unit], condition: Bool = false, list: Bool = false) -> String {
        var units = trim(input)
        if condition { units = comparing(units) }
        units = resolve(units)
        units = joinNames(units)
        units = restoreSubjects(units)
        if list { units = separate(units) }
        return render(structure(units, list: list))
    }

    /// In a condition nothing can be assigned: "equals" is `=`, and so is an
    /// "is" between two values ("if found is true").
    private static func comparing(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        var index = 0
        var between = false
        while index < units.count {
            let unit = units[index]
            // "mark is between 50 and 60": both ends included, the way the
            // syllabus's own range checks are written.
            if bare(unit) == "is", bare(units[safe: index + 1]) == "between" {
                index += 1
                continue
            }
            if bare(unit) == "between", isValue(out.last) {
                out.append(.op(">="))
                between = true
            } else if between, unit == .keyword("AND") {
                out.append(contentsOf: [unit, .op("<=")])
                between = false
            } else if unit == .op("←") {
                out.append(.op("="))
            } else if bare(unit) == "is", units[safe: index + 1] == .keyword("NOT") {
                out.append(.op("<>"))
                index += 1
            } else if bare(unit) == "is", isValue(out.last), startsValue(units[safe: index + 1]) {
                out.append(.op("="))
            } else {
                out.append(unit)
            }
            index += 1
        }
        return out
    }

    /// A library routine is one only when a value follows it; "year equals
    /// 2024" and "birth year" are names.
    private static func resolve(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        for (index, unit) in units.enumerated() {
            if case .builtin(let name, let spoken) = unit {
                var next = units[safe: index + 1]
                if bare(next) == "of" { next = units[safe: index + 2] }
                let afterName: Bool = {
                    if case .word? = out.last { return true } else { return false }
                }()
                let called: Bool
                if arity[name] == 0 {
                    called = !afterName && !isWord(next)
                } else {
                    called = !afterName && (next == .open("(") || startsValue(next))
                }
                if called {
                    out.append(unit)
                } else {
                    out.append(contentsOf: spoken.split(separator: " ").map { .word(String($0)) })
                }
                continue
            }
            if bare(unit) == "of", case .builtin? = out.last { continue }
            out.append(unit)
        }
        return out
    }

    private static func isWord(_ unit: Unit?) -> Bool {
        if case .word? = unit { return true }
        return false
    }

    private static func isName(_ unit: Unit?) -> Bool {
        if case .name? = unit { return true }
        return false
    }

    private static func isNumber(_ unit: Unit?) -> Bool {
        if case .number? = unit { return true }
        return false
    }

    static func isComma(_ unit: Unit?) -> Bool {
        if case .comma? = unit { return true }
        return false
    }

    /// "total marks" is `TotalMarks`; "pupil 1" is `Pupil1`; "total
    /// underscore marks" is `Total_Marks`.
    private static func joinNames(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        var run = ""
        var open = false
        func flush() {
            if !run.isEmpty { out.append(.name(run)) }
            run = ""
            open = false
        }
        for (index, unit) in units.enumerated() {
            switch unit {
            case .word(let word):
                run += pascal(word)
                open = true
            case .glue:
                if open, isWord(units[safe: index + 1]) || isNumber(units[safe: index + 1]) {
                    run += "_"
                }
            case .number(let number) where open && number.allSatisfy(\.isNumber):
                run += number
            default:
                flush()
                out.append(unit)
            }
        }
        flush()
        return out
    }

    static func pascal(_ word: String) -> String {
        let kept = word.filter { $0.isLetter || $0.isNumber || $0 == "_" }
        return kept.prefix(1).uppercased() + kept.dropFirst()
    }

    /// "Mark is greater than 0 and less than 50": the second comparison's
    /// subject was not said again, and Cambridge needs it.
    private static func restoreSubjects(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        for (index, unit) in units.enumerated() {
            out.append(unit)
            guard unit == .keyword("AND") || unit == .keyword("OR"),
                  case .op(let next)? = units[safe: index + 1], comparisons.contains(next),
                  let previous = out.dropLast().lastIndex(where: {
                      if case .op(let mark) = $0 { return comparisons.contains(mark) }
                      return false
                  })
            else { continue }
            var subject: [Unit] = []
            var cursor = previous - 1
            var depth = 0
            while cursor >= 0 {
                let candidate = out[cursor]
                if candidate == .close("]") {
                    depth += 1
                } else if candidate == .open("[") {
                    depth -= 1
                    if depth < 0 { break }
                } else if depth == 0 {
                    guard candidate == .dot || isName(candidate) else { break }
                }
                subject.insert(candidate, at: 0)
                cursor -= 1
            }
            if case .name? = subject.first { out.append(contentsOf: subject) }
        }
        return out
    }

    /// OUTPUT's items: a string next to a value is two items, and so is AND
    /// beside a string — it cannot be the logical AND of a string.
    private static func separate(_ units: [Unit]) -> [Unit] {
        var out: [Unit] = []
        var depth = 0
        for (index, unit) in units.enumerated() {
            let isText: (Unit?) -> Bool = { if case .text? = $0 { return true } else { return false } }
            if depth == 0, unit == .keyword("AND"),
               isText(out.last) || isText(units[safe: index + 1]),
               isValue(out.last), startsValue(units[safe: index + 1]) {
                out.append(.comma(hard: true))
                continue
            }
            if depth == 0, isValue(out.last), startsValue(unit), isText(out.last) || isText(unit) {
                out.append(.comma(hard: true))
            }
            switch unit {
            case .open: depth += 1
            case .close: depth = max(0, depth - 1)
            default: break
            }
            out.append(unit)
        }
        return out
    }

    private struct Open {
        var mark: String
        var automatic: Bool
        var routine: String?
        var arguments: Int
        var closer: String { mark == "[" ? "]" : ")" }
    }

    /// Opens a routine's brackets and closes every bracket: at a comparison,
    /// an assignment or a keyword for automatic ones, at "close" or the end
    /// for the rest. A square bracket is always closed automatically — an
    /// index never holds a comparison.
    private static func structure(_ units: [Unit], list: Bool) -> [Unit] {
        var out: [Unit] = []
        var stack: [Open] = []
        func closeTop() { out.append(.close(stack.removeLast().closer)) }
        func closeAutomatic() { while stack.last?.automatic == true { closeTop() } }
        func closeSingle() {
            while let top = stack.last, top.automatic, let routine = top.routine,
                  singleOperand.contains(routine) {
                closeTop()
            }
        }

        for (index, unit) in units.enumerated() {
            let next = units[safe: index + 1]
            switch unit {
            case .builtin(let name, _):
                out.append(unit)
                if next == .open("(") { continue }
                if arity[name] == 0 {
                    out.append(contentsOf: [.open("("), .close(")")])
                } else {
                    out.append(.open("("))
                    stack.append(Open(mark: "(", automatic: true, routine: name, arguments: 1))
                }
            case .op(let mark):
                if comparisons.contains(mark) || mark == "←" { closeAutomatic() } else { closeSingle() }
                out.append(unit)
            case .keyword(let keyword):
                if ["AND", "OR", "TO", "THEN", "DO", "STEP", "OF", "FOR"].contains(keyword) {
                    closeAutomatic()
                } else if keyword == "MOD" || keyword == "DIV" {
                    closeSingle()
                }
                out.append(unit)
            case .open(let mark):
                out.append(unit)
                stack.append(Open(mark: mark, automatic: mark == "[", routine: nil, arguments: 1))
            case .close(let mark):
                if mark.isEmpty {
                    if !stack.isEmpty { closeTop() }
                } else if let match = stack.lastIndex(where: { $0.closer == mark }) {
                    while stack.count > match { closeTop() }
                }
            case .comma(let hard):
                var after = index + 1
                while case .comma(hard: false)? = units[safe: after] { after += 1 }
                guard hard || (isValue(out.last) && startsValue(units[safe: after])
                               && (list || !stack.isEmpty)) else { continue }
                while let top = stack.last, top.automatic, let routine = top.routine,
                      top.arguments >= arity[routine] ?? 1 {
                    closeTop()
                }
                if !stack.isEmpty { stack[stack.count - 1].arguments += 1 }
                out.append(.comma(hard: true))
            default:
                out.append(unit)
            }
        }
        while !stack.isEmpty { closeTop() }
        return out
    }

    static func isValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word?, .name?, .number?, .text?, .close?: return true
        case .keyword(let keyword)?: return keyword == "TRUE" || keyword == "FALSE"
        default: return false
        }
    }

    static func startsValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word?, .name?, .number?, .text?, .builtin?, .open("(")?, .op("-")?: return true
        case .keyword(let keyword)?: return ["TRUE", "FALSE", "NOT"].contains(keyword)
        default: return false
        }
    }

    static func render(_ units: [Unit]) -> String {
        var text = ""
        var previous: Unit?
        var brackets: [String] = []
        var unary = false
        for unit in units {
            var piece: String
            var space = previous != nil
            switch unit {
            case .word(let word): piece = pascal(word)
            case .keyword(let keyword): piece = keyword
            case .builtin(let name, _): piece = name
            case .name(let name): piece = name
            case .number(let number): piece = number
            case .text(let literal): piece = literal
            case .op(let mark): piece = mark
            case .open(let mark):
                piece = mark
                switch previous {
                case .name?, .builtin?, .close?, .word?: space = false
                default: break
                }
                brackets.append(mark)
            case .close(let mark):
                piece = mark
                space = false
                if !brackets.isEmpty { brackets.removeLast() }
            case .comma:
                piece = ","
                space = false
            case .colon:
                piece = ":"
                if brackets.last == "[" { space = false }
            case .dot:
                piece = "."
                space = false
            case .glue:
                piece = "_"
                space = false
            }
            switch previous {
            case .open?, .dot?, .glue?: space = false
            case .colon? where brackets.last == "[": space = false
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

private typealias PD = PseudocodeDictation
