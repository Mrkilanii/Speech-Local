import Foundation

/// Spoken TypeScript becomes TypeScript.
///
///     "const user name equals quote omar"   ->  const userName = "omar";
///     "if count equals 0"                    ->  if (count === 0) {
///     "numbers dot map n arrow n times 2"    ->  numbers.map((n) => n * 2);
///     "close block"                          ->  }
///
/// The approach is `PythonDictation`'s (decision 10): the recognizer writes
/// code as prose, so capitals, full stops and pause commas are stripped
/// outside strings and the language is put back by rules. What TypeScript
/// changes:
///
/// * **Names are camelCase**: "user name" is `userName`. After `class`,
///   `interface`, `type`, `enum`, `extends`, `implements` and `new` they are
///   PascalCase, and so is a type after a colon that is not a primitive.
/// * **A block opens with ` {` and closes when told.** A line that starts
///   with `if`/`else`/`for`/`while`/`function`/`class`/`interface`/`try`…,
///   or ends with an arrow, gets ` {`; "close block" (or "end block", "close
///   brace", "step out") is `}`. There is no implicit close: braces are
///   visible and a guessed one would be wrong silently. The one exception is
///   `else`/`catch`/`finally`, which always close the block before them.
/// * **Statements end with `;`**, members of an object literal with `,`.
/// * **"equals" is `=`, except in an `if` or `while` condition**, where an
///   assignment is never what was meant and it is `===`.
public enum TypeScriptDictation {
    public typealias Line = PythonDictation.Line

    /// The whole dictation as text, indented from column 0.
    public static func apply(to transcript: String) -> String {
        block(lines(of: transcript), caretLine: nil)
    }

    /// The dictation as lines, split where the speaker said "next line" and
    /// around every closed block.
    public static func lines(of transcript: String) -> [Line] {
        let transcript = CodeConfusions.apply(transcript, for: .typescript)
        let tokens = PythonDictation.tidyGlue(
            Token.split(transcript).filter { !PythonDictation.fillers.contains(Token.word($0)) }
        ).flatMap(PythonDictation.unglueQuote)

        var out: [Line] = []
        var blocks: [Block] = []
        for group in groups(tokens) {
            if group.closes {
                let block = blocks.popLast()
                var text = "}" + (block?.closers ?? "")
                // `};` after an arrow body or object literal; `},` inside one.
                if block?.statement == true { text += blocks.last?.kind == .object ? "," : ";" }
                out.append(Line(text: text, breakBefore: true, dedent: 1))
                continue
            }
            let compiled = compile(group.tokens, context: blocks.last?.kind ?? .code)
            var text = compiled.text
            var breakBefore = group.breakBefore
            if compiled.continues {
                // `else` after "close block" joins the brace: `} else {`.
                if let last = out.last, last.text == "}" {
                    out.removeLast()
                    breakBefore = last.breakBefore
                } else if !blocks.isEmpty {
                    blocks.removeLast()
                }
                text = "} " + text
            }
            if let block = compiled.block { blocks.append(block) }
            out.append(Line(text: text, breakBefore: breakBefore,
                            dedent: text.hasPrefix("}") ? 1 : 0))
        }
        return out.filter { !$0.text.isEmpty || $0.breakBefore }
    }

    /// The lines as one piece of text, two spaces a level, from the caret
    /// line's indentation — and one level in when that line ends with `{`.
    public static func block(_ lines: [Line], caretLine: String?) -> String {
        CodeLayout.block(lines, caretLine: caretLine, open: "{", close: "}", unit: "  ",
                         mergesCloser: true, caseLabels: true)
    }

    // MARK: - Lines and blocks

    enum BlockKind: Equatable {
        case code
        /// An object literal or enum: members end with `,`.
        case object
        /// Interface members: `name: string;`.
        case interface
        /// Class members, and methods said as "name taking …".
        case classBody
        case switchBody
    }

    struct Block: Equatable {
        var kind: BlockKind
        /// Brackets the opening line left open, closed after the brace:
        /// `items.forEach((item) => {` closes with `});`.
        var closers = ""
        /// Whether the brace ends an expression, so it takes `;` or `,`.
        var statement = false
    }

    /// What ends a block. "step out" and "dedent" are here too: said in
    /// Python they meant the same thing.
    static let blockClosers: Set<String> = Set([
        "close block", "closed block", "end block", "close the block", "end brace",
        "end curly", "end if", "end for", "end while", "end function", "end class",
        "end loop", "end interface",
    ]).union(PythonDictation.dedents)

    /// Close a block unless a brace opened on the same line is still open.
    static let braceClosers: Set<String> = [
        "close curly", "closed curly", "close brace", "closed brace", "close curly brace",
        "closed curly brace",
    ]

    static let braceOpeners: Set<String> = [
        "open curly", "open brace", "open curly brace", "left curly", "curly brackets",
        "curly bracket", "squiggly brackets", "squiggly bracket", "curly", "squiggly",
    ]

    struct Group {
        var tokens: [String] = []
        var breakBefore: Bool
        var closes = false
        /// Made by a close, not by "next line": dropped if nothing follows.
        var implicit = false
    }

    static func groups(_ tokens: [String]) -> [Group] {
        var groups = [Group(breakBefore: false)]
        var inlineBraces = 0
        var index = 0
        func startLine(implicit: Bool) {
            groups.append(Group(breakBefore: true, implicit: implicit))
            inlineBraces = 0
        }
        while index < tokens.count {
            if let (_, length) = PythonDictation.phrase(
                tokens, at: index, in: PythonDictation.lineBreaks, longest: 2) {
                // "return x next. Next line" — a false start on the break.
                if Token.word(groups[groups.count - 1].tokens.last ?? "") == "next" {
                    groups[groups.count - 1].tokens.removeLast()
                }
                if groups[groups.count - 1].implicit, groups[groups.count - 1].tokens.isEmpty {
                    groups[groups.count - 1].implicit = false
                } else {
                    startLine(implicit: false)
                }
                index += length
                continue
            }
            let closer = PythonDictation.phrase(tokens, at: index, in: blockClosers, longest: 3)
                ?? (inlineBraces == 0
                    ? PythonDictation.phrase(tokens, at: index, in: braceClosers, longest: 3) : nil)
            if let (_, length) = closer {
                let current = groups[groups.count - 1]
                if current.tokens.isEmpty, !current.closes {
                    groups[groups.count - 1].closes = true
                    groups[groups.count - 1].breakBefore = true
                } else {
                    groups.append(Group(breakBefore: true, closes: true))
                }
                startLine(implicit: true)
                index += length
                continue
            }
            // Braces opened and closed on this line are an object literal's.
            if let (_, length) = PythonDictation.phrase(tokens, at: index, in: braceOpeners,
                                                        longest: 3)
                ?? PythonDictation.phrase(tokens, at: index, in: braceClosers, longest: 3) {
                let said = tokens[index..<(index + length)].map(Token.word).joined(separator: " ")
                inlineBraces += braceOpeners.contains(said) ? 1 : -1
                groups[groups.count - 1].tokens += tokens[index..<(index + length)]
                index += length
                continue
            }
            groups[groups.count - 1].tokens.append(tokens[index])
            index += 1
        }
        if groups.last?.implicit == true, groups.last?.tokens.isEmpty == true { groups.removeLast() }
        // A "next line" that opened the dictation leaves an empty first group.
        if groups.count > 1, groups[0].tokens.isEmpty, !groups[0].closes { groups.removeFirst() }
        return groups
    }

    // MARK: - One line

    struct Compiled {
        var text: String
        var block: Block?
        /// `else`, `catch`, `finally`: closes the block before it.
        var continues = false
    }

    static let modifiers: Set<String> = [
        "export", "async", "public", "private", "protected", "static", "readonly", "abstract",
    ]

    static func compile(_ raw: [String], context: BlockKind) -> Compiled {
        var tokens = openingKeyword(raw)
        var lead: [String] = []
        while let first = tokens.first.map(Token.word), tokens.count > 1,
              modifiers.contains(first) || (first == "default" && lead.last == "export") {
            lead.append(first)
            tokens.removeFirst()
        }
        let prefix = lead.map { $0 + " " }.joined()
        guard let head = tokens.first.map(Token.word) else {
            return Compiled(text: lead.joined(separator: " "), block: nil)
        }
        let rest = Array(tokens.dropFirst())

        switch head {
        case "if", "while", "switch":
            let condition = expression(trimHeader(rest), condition: true)
            return Compiled(text: prefix + head + " (" + condition + ") {",
                            block: Block(kind: head == "switch" ? .switchBody : .code))
        case "else":
            if rest.first.map(Token.word) == "if" {
                let condition = expression(trimHeader(Array(rest.dropFirst())), condition: true)
                return Compiled(text: "else if (" + condition + ") {", block: Block(kind: .code),
                                continues: true)
            }
            return Compiled(text: "else {", block: Block(kind: .code), continues: true)
        case "catch":
            let binding = expression(trimHeader(rest))
            return Compiled(text: binding.isEmpty ? "catch {" : "catch (" + binding + ") {",
                            block: Block(kind: .code), continues: true)
        case "finally":
            return Compiled(text: "finally {", block: Block(kind: .code), continues: true)
        case "try", "do":
            return Compiled(text: head + " {", block: Block(kind: .code))
        case "for":
            var header = expression(trimHeader(rest), forHeader: true)
            if !["const ", "let ", "var "].contains(where: header.hasPrefix),
               header.contains(" of ") || header.contains(" in ") {
                header = "const " + header
            }
            return Compiled(text: "for (" + header + ") {", block: Block(kind: .code))
        case "case":
            return Compiled(text: "case " + expression(trimHeader(rest)) + ":", block: nil)
        case "default" where rest.isEmpty:
            return Compiled(text: "default:", block: nil)
        default:
            return statement(tokens, prefix: prefix, context: context)
        }
    }

    /// Declarations with a body, and everything else.
    private static func statement(_ tokens: [String], prefix: String, context: BlockKind) -> Compiled {
        let head = Token.word(tokens[0])
        var words = tokens
        let declaration: BlockKind?
        switch head {
        case "function", "constructor": declaration = .code
        case "class": declaration = .classBody
        case "interface": declaration = .interface
        case "enum": declaration = .object
        default:
            // A method is said the way a function is, without the keyword:
            // "greet taking name", or "method greet".
            let isMethod = context == .classBody
                && (head == "method" || words.map(Token.word).contains("taking"))
            if head == "method" { words.removeFirst() }
            declaration = isMethod ? .code : nil
        }

        let units = shape(lex(words), context: context)
        var (out, open) = structure(units, objectContext: context == .object)

        if let declaration {
            // `function greet() {`: a function with nothing passed still has
            // its brackets.
            let nameAt = declaration == .code ? (head == "function" ? 1 : 0) : nil
            if let nameAt, out.count > nameAt, !out.contains(.open("(")) {
                out.insert(contentsOf: [.open("("), .close(")")], at: nameAt + 1)
            }
            closeAll(&out, &open)
            return Compiled(text: prefix + render(out) + " {", block: Block(kind: declaration))
        }
        if out.last == .op("=>") {
            let closers = open.reversed().map(\.closer).joined()
            return Compiled(text: prefix + render(out) + " {",
                            block: Block(kind: .code, closers: closers, statement: true))
        }
        if out.last == .open("{"), open.last?.mark == "{" {
            open.removeLast()
            let closers = open.reversed().map(\.closer).joined()
            return Compiled(text: prefix + render(out),
                            block: Block(kind: .object, closers: closers, statement: true))
        }
        closeAll(&out, &open)
        let text = prefix + render(out)
        guard !text.isEmpty, !text.hasSuffix(";"), !text.hasSuffix(","), !text.hasSuffix(":") else {
            return Compiled(text: text, block: nil)
        }
        return Compiled(text: text + (context == .object ? "," : ";"), block: nil)
    }

    private static func closeAll(_ out: inout [Unit], _ open: inout [Open]) {
        while let last = open.popLast() { out.append(.close(last.closer)) }
    }

    /// An expression on its own: a condition, a `for` header, a `${…}`.
    static func expression(_ tokens: [String], condition: Bool = false,
                           forHeader: Bool = false) -> String {
        var (out, open) = structure(shape(lex(tokens), context: .code, condition: condition,
                                          forHeader: forHeader), objectContext: false)
        closeAll(&out, &open)
        return render(out)
    }

    /// "then", a Python colon, or a spoken brace at the end of a header: the
    /// brace is written anyway.
    static func trimHeader(_ tokens: [String]) -> [String] {
        var tokens = tokens
        while let last = tokens.last {
            let word = Token.word(last)
            if ["then", "colon", "do"].contains(word) {
                tokens.removeLast()
            } else if tokens.count >= 2,
                      ["open curly", "open brace", "open block"].contains(
                        Token.word(tokens[tokens.count - 2]) + " " + word) {
                tokens.removeLast(2)
            } else {
                break
            }
        }
        return tokens
    }

    /// What the recognizer makes of the words that open a line, measured on
    /// Omar's voice for Python (decision 10): `else` as "L" and "LS", `elif`
    /// as "LF". Here both mean `else`/`else if`.
    static func openingKeyword(_ tokens: [String]) -> [String] {
        guard let first = tokens.first else { return tokens }
        let word = Token.word(first)
        let second = tokens.dropFirst().first.map(Token.word)
        let rest = { (count: Int) in Array(tokens.dropFirst(count)) }
        if ["lf", "elf", "elif"].contains(word) { return ["else", "if"] + rest(1) }
        if ["l", "else", "otherwise"].contains(word), second == "if" { return ["else", "if"] + rest(2) }
        if ["ls", "els", "otherwise"].contains(word) { return ["else"] + rest(1) }
        if word == "l", second == nil || second == "colon" { return ["else"] }
        if word == "constant" { return ["const"] + rest(1) }
        // "for each item in items" iterates the items: `of`, not `in`.
        if ["for", "4", "four", "fore"].contains(word), second == "each" {
            var header = rest(2)
            if let at = header.firstIndex(where: { Token.word($0) == "in" }) { header[at] = "of" }
            return ["for"] + header
        }
        // "4 item of items" — "for" heard as the number.
        if ["4", "four", "fore"].contains(word),
           tokens.dropFirst().prefix(5).map(Token.word).contains(where: { $0 == "of" || $0 == "in" }) {
            return ["for"] + rest(1)
        }
        return tokens
    }

    // MARK: - Units

    enum Kind: Equatable {
        case unknown, keyword, callable, property, global, type
    }

    enum Unit: Equatable {
        case word(String, Kind)
        case number(String)
        case text(String)
        case op(String)
        case open(String)
        /// An empty closer means "whatever is innermost".
        case close(String)
        /// Soft commas are the recognizer's pauses; kept only between values.
        case comma(hard: Bool)
        case colon
        case dot
        case semicolon
        /// "returns": closes the parameters and starts the return type.
        case returns
    }

    // MARK: - Lexing: tokens to units

    static let commands: [String: [Unit]] = {
        var table: [String: [Unit]] = [:]
        func add(_ unit: Unit, _ phrases: String...) {
            for phrase in phrases { table[phrase] = [unit] }
        }
        add(.open("("), "open paren", "open parenthesis", "open bracket", "open round bracket",
            "left paren", "paren", "taking")
        add(.close(")"), "close paren", "closed paren", "close parenthesis", "close bracket",
            "closed bracket", "right paren")
        add(.open("["), "open square", "open square bracket", "left square", "square brackets",
            "square bracket")
        add(.close("]"), "close square", "closed square", "close square bracket")
        add(.open("{"), "open curly", "open brace", "open curly brace", "left curly",
            "curly brackets", "curly bracket", "squiggly brackets", "squiggly bracket")
        add(.close("}"), "close curly", "closed curly", "close brace", "closed brace",
            "close curly brace", "closed curly brace")
        for phrase in PythonDictation.outsidePhrases { table[phrase] = [.close("")] }
        add(.close(""), "close", "closed")
        table["empty array"] = [.open("["), .close("]")]
        table["empty object"] = [.open("{"), .close("}")]
        add(.comma(hard: true), "comma")
        add(.colon, "colon")
        add(.dot, "dot")
        add(.semicolon, "semicolon", "semi colon")
        add(.returns, "returns", "returning")
        add(.op("=>"), "arrow", "fat arrow", "arrow function")
        add(.op("="), "equals", "equal", "is equals", "equal sign", "equals sign")
        add(.op("==="), "triple equals", "equals equals equals", "is equal to", "equal to",
            "strictly equals", "strictly equal to", "is strictly equal to")
        add(.op("=="), "double equals", "equals equals")
        add(.op("!=="), "not equal", "not equals", "not equal to", "is not equal to",
            "does not equal", "doesn't equal", "is not", "strictly not equal", "not triple equals")
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
        add(.op("+="), "plus equals")
        add(.op("-="), "minus equals")
        add(.op("*="), "times equals")
        add(.op("/="), "divide equals", "divided equals")
        // Not "increment" or "decrement": both are ordinary method names.
        add(.op("++"), "plus plus")
        add(.op("--"), "minus minus")
        add(.op("+"), "plus")
        add(.op("-"), "minus", "negative")
        add(.op("*"), "times", "multiplied by")
        add(.op("/"), "divided by")
        add(.op("%"), "modulo")
        add(.op("**"), "to the power of")
        add(.op("&&"), "and", "double and", "double ampersand")
        add(.op("||"), "or", "double pipe")
        add(.op("??"), "nullish", "double question mark")
        add(.op("!"), "not", "bang")
        add(.op("..."), "spread", "dot dot dot")
        return table
    }()

    static let commandPhrases = Set(commands.keys)
    static let longestCommand = commands.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// String openers and the quote each writes. Every string is
    /// double-quoted; a template is backticked.
    static let stringOpeners: [String: String] = [
        "quote": "\"", "quotes": "\"", "quotation mark": "\"", "quotation marks": "\"",
        "double quote": "\"", "single quote": "\"", "open quote": "\"",
        "template string": "`", "template literal": "`", "backtick": "`", "back tick": "`",
        "backticks": "`",
    ]

    static let quoteClosers: Set<String> = Set([
        "close quote", "closed quote", "end quote", "unquote", "quote", "quotes",
        "quotation mark", "quotation marks", "single quote", "double quote",
    ]).union(PythonDictation.outsidePhrases)

    /// "outside of brackets" is not here: in a template it ends `${…}`.
    static let templateClosers: Set<String> = [
        "close backtick", "closed backtick", "end backtick", "backtick", "back tick",
        "end template", "close template", "end template string",
    ]

    static func lex(_ raw: [String]) -> [Unit] {
        var units: [Unit] = []
        var code: [String] = []
        func flushCode() {
            guard !code.isEmpty else { return }
            units.append(contentsOf: lexCode(SpokenNumbers.apply(to: code)))
            code = []
        }
        let openers = Set(stringOpeners.keys)
        var index = 0
        while index < raw.count {
            let word = Token.word(raw[index])
            if ["close", "closed", "end"].contains(word), let next = raw[safe: index + 1],
               ["quote", "quotes", "backtick"].contains(Token.word(next)) {
                index += 2
                continue
            }
            guard let (opener, length) = PythonDictation.phrase(raw, at: index, in: openers,
                                                                longest: 2) else {
                code.append(raw[index])
                index += 1
                continue
            }
            flushCode()
            let quote = stringOpeners[opener]!
            let closers = quote == "`" ? templateClosers : quoteClosers
            var cursor = index + length
            var content: [String] = []
            var closed = false
            var leavesBracket = false
            var pause = false
            while cursor < raw.count {
                if let (closer, length) = PythonDictation.phrase(raw, at: cursor, in: closers,
                                                                 longest: 6) {
                    cursor += length
                    closed = true
                    leavesBracket = closer.hasPrefix("outside")
                    break
                }
                // "quote click comma event arrow": nobody closes the quote
                // before the next argument. A comma ends the string only when
                // what follows is plainly code (another string, a figure, or
                // an arrow), so "hello comma world" stays one message.
                if Token.word(raw[cursor]) == "comma", endsArgument(raw, from: cursor + 1) { break }
                content.append(raw[cursor])
                cursor += 1
                if Token.parts(of: raw[cursor - 1]).trailing.hasSuffix(","),
                   endsArgument(raw, from: cursor) {
                    pause = true
                    break
                }
            }
            units.append(.text(quote == "`" ? template(content, closed: closed)
                               : PythonDictation.literal(content, opener: quote, closed: closed)))
            if leavesBracket { units.append(.close("")) }
            if pause { units.append(.comma(hard: false)) }
            if closed {
                units.append(contentsOf: trailingUnits(raw[cursor - 1], next: raw[safe: cursor],
                                                       afterCommand: true))
            }
            index = cursor
        }
        flushCode()
        return units
    }

    /// Whether the words from here start another argument rather than more
    /// text: a string, a figure, or anything with an arrow before the line ends.
    static func endsArgument(_ tokens: [String], from start: Int) -> Bool {
        guard let first = tokens[safe: start] else { return false }
        if PythonDictation.phrase(tokens, at: start, in: Set(stringOpeners.keys), longest: 2) != nil
            || SpokenNumbers.isFigure(first) {
            return true
        }
        var index = start
        while index < tokens.count {
            if PythonDictation.phrase(tokens, at: index, in: PythonDictation.lineBreaks,
                                      longest: 2) != nil { return false }
            if Token.word(tokens[index]) == "arrow" { return true }
            index += 1
        }
        return false
    }

    static let interpolationOpeners: Set<String> = [
        "dollar curly", "dollar sign curly", "dollar brace", "dollar sign brace",
        "dollar curly brace", "dollar sign curly brace", "dollar curly brackets",
        "dollar sign curly brackets", "dollar squiggly brackets", "dollar sign squiggly brackets",
        "dollar squiggly", "dollar open curly", "curly", "open curly", "curly brackets",
        "squiggly brackets", "squiggly",
    ]

    static let interpolationClosers: Set<String> = Set([
        "close curly", "closed curly", "close brace", "closed brace", "end curly",
        "close curly brace",
    ]).union(PythonDictation.outsidePhrases)

    /// A template literal: "hello dollar curly name close curly" is
    /// `` `hello ${name}` ``. The expression inside is dictated code; the rest
    /// is text, with spoken punctuation ("slash", "dot") applied.
    static func template(_ words: [String], closed: Bool) -> String {
        let words = words.map { $0 == "$" ? "dollar" : $0 }
        var body: [String] = []
        var expressions: [String] = []
        var index = 0
        while index < words.count {
            guard let (_, length) = PythonDictation.phrase(words, at: index,
                                                           in: interpolationOpeners, longest: 4)
            else {
                body.append(words[index])
                index += 1
                continue
            }
            var cursor = index + length
            var inner: [String] = []
            while cursor < words.count {
                if let (_, length) = PythonDictation.phrase(words, at: cursor,
                                                            in: interpolationClosers, longest: 6) {
                    cursor += length
                    break
                }
                inner.append(words[cursor])
                cursor += 1
            }
            // A placeholder made of letters survives spoken punctuation
            // joining it to its neighbours ("slash", "dot"); `${` would not.
            body.append("zqslot\(expressions.count)qz")
            expressions.append(expression(inner))
            index = cursor
        }
        var text = PythonDictation.literal(body, opener: "`", closed: closed)
        for (number, code) in expressions.enumerated() {
            text = text.replacingOccurrences(of: "zqslot\(number)qz", with: "${" + code + "}")
        }
        return text
    }

    private static func lexCode(_ tokens: [String]) -> [Unit] {
        var units: [Unit] = []
        var index = 0
        while index < tokens.count {
            // After a dot every word is a member: `promise.catch`, `f.close`.
            if units.last != .dot,
               let (phrase, length) = PythonDictation.phrase(
                tokens, at: index, in: commandPhrases, longest: longestCommand) {
                units.append(contentsOf: commands[phrase]!)
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
        "=", "===", "==", "!==", "!=", "=>", "+", "-", "*", "/", "%", "**", "<", ">", "<=", ">=",
        "&&", "||", "!", "++", "--", "+=", "-=", "*=", "/=", "??", "...",
    ]

    private static func tokenUnits(_ token: String, next: String?) -> [Unit] {
        let parts = Token.parts(of: token)
        if parts.core.isEmpty {
            let symbol = parts.leading + parts.trailing
            if symbolOps.contains(symbol) {
                return [.op(symbol == "!=" ? "!==" : symbol == "==" ? "===" : symbol)]
            }
            return symbol.compactMap(bracket)
        }
        var units = parts.leading.compactMap(bracket)
        // "console.log" and "this.name" arrive as one token.
        for (position, piece) in CodeLayout.figure(parts.core).split(
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

    /// The recognizer's punctuation, read the way `PythonDictation` measured
    /// it: a comma between figures was spoken, any other is a pause; a full
    /// stop is a dot only before a lowercase word.
    private static func trailingUnits(_ token: String, next: String?, afterCommand: Bool) -> [Unit] {
        let parts = Token.parts(of: token)
        let isFigure = !parts.core.isEmpty && parts.core.allSatisfy(\.isNumber)
            && next.map(SpokenNumbers.isFigure) == true
        var units: [Unit] = []
        for character in parts.trailing {
            switch character {
            case ",": units.append(.comma(hard: isFigure && !afterCommand))
            case ":": units.append(.colon)
            case ";": units.append(.semicolon)
            case ")", "]", "}": units.append(.close(String(character)))
            case ".":
                if parts.trailing == ".", next?.first?.isLowercase == true { units.append(.dot) }
            default: break
            }
        }
        return units
    }

    // MARK: - Shaping: words to names

    static let keywords: Set<String> = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
        "switch", "case", "break", "continue", "class", "interface", "enum", "extends",
        "implements", "new", "this", "super", "async", "await", "import", "export", "in",
        "typeof", "instanceof", "try", "catch", "finally", "throw", "true", "false", "null",
        "undefined", "void", "public", "private", "protected", "readonly", "static", "as",
        "yield", "delete", "abstract",
    ]

    /// Primitive types, written in lowercase where a type goes.
    static let primitives: Set<String> = [
        "string", "number", "boolean", "any", "unknown", "never", "object", "bigint", "symbol",
    ]

    /// Keywords after which the next name is a type's: PascalCase.
    static let pascalIntroducers: Set<String> = [
        "class", "interface", "type", "enum", "extends", "implements", "new",
    ]

    /// Globals that are objects, written with their own capitals, only
    /// directly before a dot: "math dot floor" is `Math.floor`, "math" alone
    /// is someone's variable.
    static let globalObjects: [String: String] = [
        "console": "console", "math": "Math", "json": "JSON", "promise": "Promise",
        "object": "Object", "array": "Array", "number": "Number", "string": "String",
        "date": "Date", "document": "document", "window": "window",
        "localstorage": "localStorage", "sessionstorage": "sessionStorage",
    ]

    static let globalFunctions: [String: String] = [
        "fetch": "fetch", "parseint": "parseInt", "parsefloat": "parseFloat",
        "settimeout": "setTimeout", "setinterval": "setInterval",
        "cleartimeout": "clearTimeout", "clearinterval": "clearInterval",
        "structuredclone": "structuredClone", "isnan": "isNaN",
    ]

    /// Members by owner, then those any object may have. Squashed spelling
    /// (lowercase, no spaces) to the real one; `*` marks a property, which is
    /// never called.
    static let ownerMembers: [String: [String]] = [
        "console": ["log", "error", "warn", "info", "table", "debug"],
        "Math": ["floor", "ceil", "round", "max", "min", "random", "abs", "sqrt", "pow",
                 "trunc", "sign", "*PI"],
        "JSON": ["stringify", "parse"],
        "Promise": ["all", "allSettled", "race", "resolve", "reject", "any"],
        "Object": ["keys", "values", "entries", "assign", "freeze", "fromEntries"],
        "Array": ["isArray", "from", "of"],
        "Number": ["isInteger", "isNaN", "parseFloat", "parseInt"],
        "document": ["getElementById", "querySelector", "querySelectorAll", "createElement",
                     "addEventListener", "*body"],
        "localStorage": ["getItem", "setItem", "removeItem", "clear"],
    ]

    static let anyMembers: [String] = [
        "map", "filter", "reduce", "forEach", "push", "pop", "shift", "unshift", "slice",
        "splice", "includes", "indexOf", "find", "findIndex", "some", "every", "join", "sort",
        "reverse", "concat", "flat", "flatMap", "fill", "split", "trim", "toUpperCase",
        "toLowerCase", "replace", "replaceAll", "startsWith", "endsWith", "charAt", "substring",
        "padStart", "padEnd", "repeat", "toString", "toFixed", "then", "catch", "finally",
        "json", "text", "get", "set", "has", "delete", "add", "clear", "addEventListener",
        "removeEventListener", "appendChild", "setAttribute", "getAttribute", "querySelector",
        "getItem", "setItem", "*length", "*size", "*innerHTML", "*textContent",
    ]

    private static func table(_ names: [String]) -> [String: (String, Kind)] {
        var table: [String: (String, Kind)] = [:]
        for name in names {
            let property = name.hasPrefix("*")
            let spelling = property ? String(name.dropFirst()) : name
            table[spelling.lowercased()] = (spelling, property ? .property : .callable)
        }
        return table
    }

    static let ownerTables = ownerMembers.mapValues(table)
    static let anyTable = table(anyMembers)

    /// The member a run of words after a dot names, and how many it took.
    static func member(of owner: String?, words: [String]) -> (String, Kind, Int)? {
        let scopes = [owner.flatMap { ownerTables[$0] }, anyTable].compactMap { $0 }
        for length in stride(from: min(4, words.count), through: 1, by: -1) {
            let key = words[0..<length].joined()
            for scope in scopes {
                if let (spelling, kind) = scope[key] { return (spelling, kind, length) }
            }
        }
        return nil
    }

    static func camel(_ words: [String]) -> String {
        guard let first = words.first else { return "" }
        return first + words.dropFirst().map(capitalized).joined()
    }

    static func pascal(_ words: [String]) -> String {
        words.map(capitalized).joined()
    }

    private static func capitalized(_ word: String) -> String {
        word.prefix(1).uppercased() + word.dropFirst()
    }

    static func shape(_ input: [Unit], context: BlockKind, condition: Bool = false,
                      forHeader: Bool = false) -> [Unit] {
        // Keywords first, so runs of names stop at them.
        var units: [Unit] = []
        for (index, unit) in input.enumerated() {
            guard case .word(let word, _) = unit, input[safe: index - 1] != .dot else {
                units.append(unit)
                continue
            }
            let lineStart = index == 0
            if keywords.contains(word)
                || (word == "type" && lineStart && input.count > 1)
                || (word == "constructor" && lineStart)
                || (word == "of" && forHeader)
                || (word == "from" && [.word("import", .unknown), .word("export", .unknown)]
                    .contains(input.first)) {
                units.append(.word(word, .keyword))
            } else {
                units.append(unit)
            }
        }
        // "log x" is `console.log(x)`; "console log x" dropped the dot.
        if case .word("log", .unknown)? = units.first,
           ![.dot, .op("="), .colon].contains(units[safe: 1]) {
            units.replaceSubrange(0..<1, with: [.word("console", .global), .dot,
                                                .word("log", .callable)])
        } else if units.first == .word("console", .unknown),
                  case .word(let method, .unknown)? = units[safe: 1],
                  ownerTables["console"]?[method] != nil {
            units.insert(.dot, at: 1)
        }

        let typeLine = units.first == .word("type", .keyword)
        var out: [Unit] = []
        var opens: [String] = []
        var typeMode = false
        var generics = 0
        func endType() {
            guard typeMode else { return }
            for _ in 0..<generics { out.append(.close(">")) }
            generics = 0
            typeMode = false
        }

        var index = 0
        while index < units.count {
            let unit = units[index]
            switch unit {
            case .open(let mark):
                endType()
                opens.append(mark)
                out.append(unit)
            case .close:
                endType()
                if !opens.isEmpty { opens.removeLast() }
                out.append(unit)
            case .colon:
                out.append(unit)
                // `name: string`, unless it is a key in an object literal.
                if opens.last != "{", context != .object, !condition { typeMode = true }
            case .returns:
                out.append(unit)
                typeMode = true
            case .comma, .semicolon:
                endType()
                out.append(unit)
            case .op(let op):
                if typeMode, op == "||" || op == "&&" {
                    out.append(.op(op == "||" ? "|" : "&"))
                    break
                }
                endType()
                out.append(condition && op == "=" ? .op("===") : unit)
                if typeLine, op == "=" { typeMode = true }
            case .word(let word, .keyword):
                if typeMode, ["null", "undefined", "void"].contains(word) {
                    out.append(.word(word, .type))
                } else {
                    endType()
                    out.append(unit)
                }
            case .word:
                if out.last == .dot {
                    // A member's words may include a keyword: "to upper case".
                    var words: [String] = []
                    while words.count < 4, case .word(let word, _)? = units[safe: index + words.count] {
                        words.append(word)
                    }
                    var owner: String?
                    if case .word(let name, _)? = out[safe: out.count - 2] { owner = name }
                    if let (spelling, kind, used) = member(of: owner, words: words) {
                        out.append(.word(spelling, kind))
                        index += used
                    } else {
                        // Someone's own property: "user dot first name".
                        let run = wordRun(units, from: index)
                        let name = run.isEmpty ? [words[0]] : run
                        out.append(.word(camel(name), .property))
                        index += name.count
                    }
                    continue
                }
                let run = wordRun(units, from: index)
                index += run.count
                if typeMode {
                    for piece in typeUnits(run) {
                        if piece == .open("<") { generics += 1 }
                        out.append(piece)
                    }
                    continue
                }
                if case .word(let keyword, .keyword)? = out.last {
                    if pascalIntroducers.contains(keyword) {
                        out.append(.word(pascal(run), .type))
                        continue
                    }
                    // The name being declared takes every word said for it.
                    if ["function", "const", "let", "var"].contains(keyword) {
                        out.append(.word(camel(run), .unknown))
                        continue
                    }
                }
                out.append(contentsOf: names(run, next: units[safe: index],
                                             condition: condition, after: out.last))
                continue
            default:
                out.append(unit)
            }
            index += 1
        }
        endType()
        return out
    }

    /// Consecutive words that are not keywords.
    private static func wordRun(_ units: [Unit], from start: Int) -> [String] {
        var words: [String] = []
        var index = start
        while case .word(let word, let kind)? = units[safe: index], kind != .keyword {
            words.append(word)
            index += 1
        }
        return words
    }

    /// A run of words outside a type: globals and names.
    private static func names(_ run: [String], next: Unit?, condition: Bool,
                              after previous: Unit?) -> [Unit] {
        // "math" before a dot is `Math`; only when it is the whole name.
        if run.count <= 2, next == .dot, let spelling = globalObjects[run.joined()] {
            return [.word(spelling, .global)]
        }
        var out: [Unit] = []
        var pending: [String] = []
        func flush() {
            if !pending.isEmpty { out.append(.word(camel(pending), .unknown)) }
            pending = []
        }
        var index = 0
        while index < run.count {
            var matched = false
            for length in stride(from: min(2, run.count - index), through: 1, by: -1) {
                if let spelling = globalFunctions[run[index..<(index + length)].joined()] {
                    flush()
                    out.append(.word(spelling, .callable))
                    index += length
                    matched = true
                    break
                }
            }
            if matched { continue }
            // "if x is 5": `is` after a value compares.
            if condition, run[index] == "is", !pending.isEmpty || isValue(out.last ?? previous) {
                flush()
                out.append(.op("==="))
                index += 1
                continue
            }
            pending.append(run[index])
            index += 1
        }
        flush()
        return out
    }

    /// Words where a type goes: "string array" is `string[]`, "user profile"
    /// is `UserProfile`, "promise of string" is `Promise<string>`.
    private static func typeUnits(_ run: [String]) -> [Unit] {
        var out: [Unit] = []
        var pending: [String] = []
        func flush() {
            if !pending.isEmpty { out.append(.word(pascal(pending), .type)) }
            pending = []
        }
        for word in run {
            if ["array", "list"].contains(word), !(pending.isEmpty && out.isEmpty) {
                flush()
                if case .word(let type, .type)? = out.last {
                    out[out.count - 1] = .word(type + "[]", .type)
                }
            } else if primitives.contains(word) {
                flush()
                out.append(.word(word, .type))
            } else if word == "of", !(pending.isEmpty && out.isEmpty) {
                flush()
                out.append(.open("<"))
            } else {
                pending.append(word)
            }
        }
        flush()
        return out
    }

    // MARK: - Structure: calls, arrows, commas

    struct Open: Equatable {
        var mark: String
        var automatic: Bool
        var closer: String {
            switch mark {
            case "[": return "]"
            case "{": return "}"
            case "<": return ">"
            default: return ")"
            }
        }
    }

    /// Calls opened for a function followed by a value, parameters wrapped
    /// for an arrow, pause commas dropped. What is still open at the end is
    /// returned, for the caller to close or to carry past a block.
    static func structure(_ units: [Unit], objectContext: Bool) -> (units: [Unit], open: [Open]) {
        var out: [Unit] = []
        var stack: [Open] = []

        func meaningful(after index: Int) -> Unit? {
            var cursor = index + 1
            while cursor < units.count, units[cursor] == .comma(hard: false) { cursor += 1 }
            return units[safe: cursor]
        }

        for (index, unit) in units.enumerated() {
            let previous = index > 0 ? units[index - 1] : nil
            switch unit {
            case .word(_, let kind):
                out.append(unit)
                let next = meaningful(after: index)
                let constructed = kind == .type && previous == .word("new", .keyword)
                let callable = kind == .callable || constructed || unit == .word("super", .keyword)
                if next == .dot || next == .open("(") { continue }
                if let next, isAssignment(next) { continue }
                if callable {
                    if startsValue(next) {
                        out.append(.open("("))
                        stack.append(Open(mark: "(", automatic: true))
                    } else if next == nil || isTerminator(next),
                              previous == .dot || constructed {
                        out.append(contentsOf: [.open("("), .close(")")])
                    }
                } else if kind == .unknown || kind == .property {
                    // `greet "omar"` is never TypeScript: a name followed
                    // straight by a literal is called with it.
                    switch units[safe: index + 1] {
                    case .text?, .number?:
                        out.append(.open("("))
                        stack.append(Open(mark: "(", automatic: true))
                    default: break
                    }
                }

            case .op("=>"):
                wrapParameters(&out, objectContext: objectContext || stack.last?.mark == "{")
                out.append(unit)

            case .open(let mark):
                out.append(unit)
                stack.append(Open(mark: mark, automatic: false))

            case .close(let mark):
                if mark.isEmpty {
                    if let open = stack.popLast() { out.append(.close(open.closer)) }
                } else if let match = stack.lastIndex(where: { $0.closer == mark }) {
                    while stack.count > match { out.append(.close(stack.removeLast().closer)) }
                }

            case .comma(let hard):
                let next = units[safe: index + 1]
                if hard || (isValue(out.last) && startsValue(next)) {
                    out.append(.comma(hard: true))
                }

            case .returns:
                while let open = stack.popLast() { out.append(.close(open.closer)) }
                out.append(.colon)

            default:
                out.append(unit)
            }
        }
        return (out, stack)
    }

    /// `n => …` becomes `(n) => …`, `a, b => …` becomes `(a, b) => …`, and a
    /// bare arrow `() => …`. The parameters run back to the bracket, operator
    /// or keyword before them.
    private static func wrapParameters(_ out: inout [Unit], objectContext: Bool) {
        var depth = 0
        var start = out.count
        var index = out.count - 1
        scan: while index >= 0 {
            switch out[index] {
            case .close: depth += 1
            case .open:
                if depth == 0 { break scan }
                depth -= 1
            case .op(let op) where depth == 0 && op != "...": break scan
            case .word(_, .keyword) where depth == 0: break scan
            case .colon where depth == 0 && objectContext: break scan
            case .comma where depth == 0:
                // Parameters are names: `("click", (event) => …)` has an
                // argument before the comma, not a parameter.
                switch out[safe: index - 1] {
                case .word(_, let kind)? where [.unknown, .property, .type].contains(kind): break
                default: break scan
                }
            default: break
            }
            start = index
            index -= 1
        }
        let segment = Array(out[start...])
        if segment.isEmpty {
            out.append(contentsOf: [.open("("), .close(")")])
        } else if segment.first == .open("("), segment.last == .close(")"),
                  isOneGroup(segment) {
            return
        } else {
            out.insert(.open("("), at: start)
            out.append(.close(")"))
        }
    }

    private static func isOneGroup(_ units: [Unit]) -> Bool {
        var depth = 0
        for (index, unit) in units.enumerated() {
            if case .open = unit { depth += 1 }
            if case .close = unit {
                depth -= 1
                if depth == 0, index < units.count - 1 { return false }
            }
        }
        return depth == 0
    }

    private static func startsValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word(let word, let kind)?:
            return kind != .keyword
                || ["this", "true", "false", "null", "undefined", "new", "await", "typeof",
                    "async", "function", "super"].contains(word)
        case .number?, .text?: return true
        case .open(let mark)?: return mark == "[" || mark == "{"
        case .op(let op)?: return ["!", "-", "..."].contains(op)
        default: return false
        }
    }

    private static func isValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .word(let word, let kind)?:
            return kind != .keyword || ["this", "true", "false", "null", "undefined"].contains(word)
        case .number?, .text?, .close?: return true
        default: return false
        }
    }

    private static func isTerminator(_ unit: Unit?) -> Bool {
        switch unit {
        case .close?, .comma?, .colon?, .op?, .semicolon?, .returns?, .word(_, .keyword)?:
            return true
        default: return false
        }
    }

    private static func isAssignment(_ unit: Unit) -> Bool {
        if case .op(let op) = unit { return ["=", "+=", "-=", "*=", "/="].contains(op) }
        return false
    }

    // MARK: - Rendering

    static func render(_ units: [Unit]) -> String {
        var text = ""
        var previous: Unit?
        var unary = false
        for unit in units {
            var space = previous != nil
            let piece: String
            switch unit {
            case .word(let word, _): piece = word
            case .number(let number): piece = number
            case .text(let literal): piece = literal
            case .op(let op):
                piece = op
                if ["++", "--"].contains(op), isValue(previous) { space = false }
            case .open(let mark):
                piece = mark
                if mark == "<" {
                    space = false
                } else if mark == "(" || mark == "[" {
                    switch previous {
                    case .word(let word, let kind)?:
                        space = kind == .keyword && !["constructor", "super", "this"].contains(word)
                    case .close?, .text?: space = false
                    default: break
                    }
                }
            case .close(let mark):
                piece = mark
                space = mark == "}" && previous != .open("{")
            case .comma: piece = ","; space = false
            case .colon: piece = ":"; space = false
            case .dot: piece = "."; space = false
            case .semicolon: piece = ";"; space = false
            case .returns: continue
            }
            switch previous {
            case .open(let mark)?:
                space = mark == "{" ? unit != .close("}") : false
            case .dot?:
                space = false
            default: break
            }
            if unary { space = false }
            unary = unit == .op("!") || unit == .op("...")
                || (unit == .op("-") && !isValue(previous))
            if space { text += " " }
            text += piece
            previous = unit
        }
        return text
    }
}
