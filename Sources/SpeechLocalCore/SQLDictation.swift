import Foundation

/// Spoken SQL becomes SQL, laid out the way Trace Table's model answers are:
/// one clause to a line, a column list one column to a line.
///
///     "select name comma exam from student where form equals quote 10A
///      order by name ascending"
///         ->  SELECT name, exam
///             FROM student
///             WHERE form = '10A'
///             ORDER BY name ASC;
///
/// Same approach as `PythonDictation` (decision 10): the recognizer writes
/// code as prose, so capitals, full stops and pause commas are stripped
/// outside strings and the language is put back by rules.
///
/// What SQL changes:
///
/// * **Keywords are uppercase, names are `snake_case`.** Words that are not SQL
///   run together into one name: "student name" is `student_name`. Trace
///   Table's own questions use Cambridge style instead (`STUDENT`,
///   `StudentName`); `Naming.cambridge` writes that.
/// * **A clause keyword starts its own line.** `FROM`, `WHERE`, `GROUP BY`,
///   `ORDER BY`, `HAVING`, `LIMIT`, the joins, `VALUES`, `SET`: nobody has to
///   say "next line" for the layout every textbook uses. "next line" still
///   breaks anywhere; a break next to a clause break is one break.
/// * **Every statement ends with `;`**, at a spoken "semicolon" or at the end
///   of the dictation, and a new `SELECT`/`INSERT`/`UPDATE`/`DELETE`/`CREATE`
///   ends the one before it. Words that start with no statement keyword are a
///   continuation of one already in the editor, and get no `;`.
/// * **A comma the recognizer heard as a pause is kept between two values**
///   ("name, exam") and dropped anywhere else ("name, from").
/// * **An unclosed string ends where the value plainly does**: at a spoken
///   "comma", before a clause keyword, or before "and"/"or" that starts a
///   new condition. Omar never says "close quote" (decision 10, C3), and a
///   string that swallowed `OR pages > 400` would be a silent wrong answer.
public enum SQLDictation {
    public typealias Line = PythonDictation.Line

    /// How names are written.
    public enum Naming: Sendable {
        /// `student_name`, `student` — the common convention, and the default.
        case snakeCase
        /// Cambridge (IGCSE / A level) style, as in Trace Table's SQL track:
        /// tables `STUDENT`, fields `StudentName`, with "id" as `ID`.
        case cambridge
    }

    /// The whole dictation as text, laid out from column 0.
    public static func apply(to transcript: String, naming: Naming = .snakeCase) -> String {
        block(lines(of: transcript, naming: naming), caretLine: nil)
    }

    /// The dictation as lines: one per clause, and one per column inside a
    /// `CREATE TABLE`.
    public static func lines(of transcript: String, naming: Naming = .snakeCase) -> [Line] {
        let transcript = CodeConfusions.apply(transcript, for: .sql)
        let tokens = PythonDictation.tidyGlue(
            Token.split(transcript).filter { !PythonDictation.fillers.contains(Token.word($0)) }
        ).flatMap(PythonDictation.unglueQuote)
        var units = lex(tokens)
        let leadingBreak = units.first == .lineBreak
        let trailingBreak = units.count > 1 && units.last == .lineBreak
        while units.first == .lineBreak { units.removeFirst() }

        var rows: [[Unit]] = []
        for statement in statements(units) {
            rows += layout(structure(shape(statement, naming: naming)))
        }
        var lines = rows.enumerated().map { index, row in
            Line(text: render(row), breakBefore: index > 0 || leadingBreak,
                 dedent: row.first == .close ? 1 : 0)
        }
        if trailingBreak { lines.append(Line(text: "", breakBefore: true, dedent: 0)) }
        return lines
    }

    /// The lines as one piece of text: four spaces a level inside an open
    /// bracket, from the caret line's indentation.
    public static func block(_ lines: [Line], caretLine: String?) -> String {
        CodeLayout.block(lines, caretLine: caretLine, open: "(", close: ")", unit: "    ")
    }

    // MARK: - Units

    enum Unit: Equatable {
        /// A word not yet decided: `shape` makes it a name, type or keyword.
        case word(String)
        case keyword(String)
        case function(String)
        case type(String)
        case name(String)
        case number(String)
        case text(String)
        case op(String)
        case star
        case open
        /// The bracket that opens a `CREATE TABLE` column list.
        case columns
        case close
        /// Soft commas are the recognizer's pauses; `structure` keeps one only
        /// where it separates two values.
        case comma(hard: Bool)
        case dot
        case end
        case lineBreak
    }

    // MARK: - Vocabulary

    /// SQL written by voice. A keyword is always a keyword; the words that are
    /// SQL only in some places ("set", "table", "date", "count") are decided
    /// in `shape`, where the statement is known.
    static let keywords: [String: String] = [
        "select": "SELECT", "from": "FROM", "where": "WHERE",
        "and": "AND", "or": "OR", "not": "NOT",
        "insert into": "INSERT INTO", "insert": "INSERT", "into": "INTO",
        "values": "VALUES", "update": "UPDATE",
        "delete from": "DELETE FROM", "delete": "DELETE",
        "create table": "CREATE TABLE", "create": "CREATE",
        "alter table": "ALTER TABLE", "alter": "ALTER",
        "drop table": "DROP TABLE", "drop": "DROP",
        "add column": "ADD COLUMN", "drop column": "DROP COLUMN", "add": "ADD",
        "primary key": "PRIMARY KEY", "foreign key": "FOREIGN KEY",
        "references": "REFERENCES", "not null": "NOT NULL", "unique": "UNIQUE",
        "default": "DEFAULT",
        "inner join": "INNER JOIN", "left join": "LEFT JOIN", "right join": "RIGHT JOIN",
        "full join": "FULL JOIN", "left outer join": "LEFT OUTER JOIN", "join": "JOIN",
        "on": "ON",
        "group by": "GROUP BY", "grouped by": "GROUP BY",
        "order by": "ORDER BY", "ordered by": "ORDER BY",
        "sort by": "ORDER BY", "sorted by": "ORDER BY",
        "having": "HAVING", "as": "AS", "distinct": "DISTINCT",
        "like": "LIKE", "not like": "NOT LIKE", "in": "IN", "not in": "NOT IN",
        "between": "BETWEEN", "not between": "NOT BETWEEN",
        "is null": "IS NULL", "is not null": "IS NOT NULL", "null": "NULL",
        "limit": "LIMIT", "ascending": "ASC", "asc": "ASC",
        "descending": "DESC", "desc": "DESC",
        "true": "TRUE", "false": "FALSE",
        "union": "UNION", "union all": "UNION ALL", "exists": "EXISTS",
    ]

    /// Spoken commands, matched on bare words, longest first.
    static let commands: [String: Unit] = {
        var table: [String: Unit] = [:]
        func add(_ unit: Unit, _ phrases: String...) {
            for phrase in phrases { table[phrase] = unit }
        }
        // SQL has one bracket, so every bracket word means it.
        add(.open, "open paren", "open parenthesis", "open bracket", "open brackets",
            "open round bracket", "left paren", "paren", "brackets", "bracket")
        add(.close, "close paren", "closed paren", "close parenthesis", "close bracket",
            "closed bracket", "close brackets", "closed brackets", "right paren",
            "close", "closed")
        for phrase in PythonDictation.outsidePhrases { table[phrase] = .close }
        add(.comma(hard: true), "comma")
        add(.dot, "dot")
        add(.end, "semicolon", "semi colon", "end statement")
        add(.star, "star", "asterisk", "everything", "all columns", "all fields",
            "all the columns", "all the fields")
        // SQL compares with a single `=`, however it is said.
        add(.op("="), "equals", "equal", "equal to", "equals to", "is equal to", "is equals",
            "double equals", "equals sign", "equal sign", "is")
        add(.op("<>"), "not equal", "not equals", "not equal to", "is not equal to",
            "is not equals", "does not equal", "doesn't equal", "is not")
        // The same variants `PythonDictation` measured: "or" heard as "are"
        // or "your", or dropped.
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
        add(.op(">="), "at least")
        add(.op("<="), "at most")
        add(.op("+"), "plus")
        add(.op("-"), "minus")
        add(.op("*"), "times", "multiplied by")
        add(.op("/"), "divided by")
        for (spoken, sql) in keywords { table[spoken] = .keyword(sql) }
        return table
    }()

    static let commandPhrases = Set(commands.keys)
    static let longestCommand = commands.keys.map { $0.split(separator: " ").count }.max() ?? 1

    /// Phrases that compare, for telling "and pages greater than" (a new
    /// condition) from "Tom and Jerry" (a string).
    static let comparisons: Set<String> = Set(commands.compactMap { phrase, unit in
        if case .op(let op) = unit, ["=", "<>", "<", ">", "<=", ">="].contains(op) { return phrase }
        return nil
    }).union(["like", "not like", "in", "not in", "between", "is null", "is not null"])

    static let stringOpeners: Set<String> = [
        "quote", "quotes", "quotation mark", "quotation marks", "single quote",
        "single quotes", "double quote", "open quote",
    ]

    static let stringClosers: Set<String> = Set([
        "close quote", "closed quote", "end quote", "unquote", "quote", "quotes",
        "quotation mark", "quotation marks", "single quote", "single quotes",
    ]).union(PythonDictation.outsidePhrases)

    /// Where an unclosed string stops without being told to: the value is
    /// over when the next clause starts.
    static let clauseWords: Set<String> = [
        "from", "where", "group by", "order by", "sort by", "sorted by", "having", "limit",
        "inner join", "left join", "right join", "join", "values", "union",
        "semicolon", "semi colon", "close paren", "closed paren", "close bracket",
        "closed bracket", "close brackets", "closed brackets", "close parenthesis",
    ]

    static let functions: [String: String] = [
        "count": "COUNT", "sum": "SUM", "avg": "AVG", "average": "AVG",
        "min": "MIN", "minimum": "MIN", "max": "MAX", "maximum": "MAX",
    ]

    /// Types a column can have, only read as types where a column's type goes.
    static let typeWords: [String: String] = [
        "integer": "INTEGER", "int": "INTEGER", "varchar": "VARCHAR", "char": "CHAR",
        "character": "CHAR", "date": "DATE", "boolean": "BOOLEAN", "bool": "BOOLEAN",
        "real": "REAL", "text": "TEXT", "float": "FLOAT", "decimal": "DECIMAL",
        "time": "TIME", "datetime": "DATETIME", "timestamp": "TIMESTAMP",
    ]

    /// Types that are never anyone's column name, so types anywhere.
    static let strictTypes: [String: String] = [
        "varchar": "VARCHAR", "integer": "INTEGER", "boolean": "BOOLEAN",
    ]

    /// Keywords after which a name is a table.
    static let tableIntroducers: Set<String> = [
        "FROM", "INTO", "INSERT INTO", "UPDATE", "CREATE TABLE", "ALTER TABLE", "DROP TABLE",
        "DELETE FROM", "REFERENCES", "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN",
        "FULL JOIN", "LEFT OUTER JOIN",
    ]

    /// Keywords that start a line of their own at the top level.
    static let clauseStarts: Set<String> = [
        "SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "LIMIT",
        "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "LEFT OUTER JOIN", "JOIN",
        "VALUES", "SET", "UNION", "UNION ALL", "ADD COLUMN", "ADD", "DROP COLUMN",
    ]

    static let statementStarts: Set<String> = [
        "SELECT", "INSERT INTO", "INSERT", "UPDATE", "DELETE FROM", "DELETE",
        "CREATE TABLE", "CREATE", "ALTER TABLE", "ALTER", "DROP TABLE", "DROP",
    ]

    // MARK: - Lexing: tokens to units

    static func lex(_ raw: [String]) -> [Unit] {
        var units: [Unit] = []
        var code: [String] = []
        func flushCode() {
            guard !code.isEmpty else { return }
            units.append(contentsOf: lexCode(SpokenNumbers.apply(to: code)))
            code = []
        }

        var index = 0
        while index < raw.count {
            let word = Token.word(raw[index])
            // "close quote" with no string open is a stray closer.
            if ["close", "closed", "end"].contains(word),
               let next = raw[safe: index + 1], ["quote", "quotes"].contains(Token.word(next)) {
                index += 2
                continue
            }
            guard let (_, length) = PythonDictation.phrase(raw, at: index, in: stringOpeners,
                                                           longest: 2) else {
                code.append(raw[index])
                index += 1
                continue
            }
            flushCode()
            var cursor = index + length
            var content: [String] = []
            var last: String?          // the token whose punctuation follows the string
            var leavesBracket = false
            while cursor < raw.count {
                if let (closer, length) = PythonDictation.phrase(
                    raw, at: cursor, in: stringClosers, longest: 6) {
                    cursor += length
                    last = raw[cursor - 1]
                    leavesBracket = closer.hasPrefix("outside")
                    break
                }
                if stopsString(raw, at: cursor) { break }
                let token = raw[cursor]
                content.append(token)
                cursor += 1
                last = token
                // "quote Grace Lin, quote FIN": a pause before the next value.
                if Token.parts(of: token).trailing.contains(","),
                   let next = raw[safe: cursor], startsValue(next) {
                    break
                }
            }
            units.append(.text(literal(content)))
            if leavesBracket { units.append(.close) }
            if let last {
                units.append(contentsOf: trailingUnits(last, next: raw[safe: cursor],
                                                       afterCommand: true))
            }
            index = cursor
        }
        flushCode()
        return units
    }

    /// Whether an unclosed string ends before this token.
    static func stopsString(_ tokens: [String], at index: Int) -> Bool {
        let word = Token.word(tokens[index])
        if word == "comma" { return true }
        if PythonDictation.phrase(tokens, at: index, in: PythonDictation.lineBreaks,
                                  longest: 2) != nil { return true }
        if PythonDictation.phrase(tokens, at: index, in: clauseWords, longest: 3) != nil {
            return true
        }
        return ["and", "or"].contains(word) && startsCondition(tokens, at: index + 1)
    }

    /// "pages greater than": a name of up to four words, then a comparison.
    static func startsCondition(_ tokens: [String], at start: Int) -> Bool {
        var index = start
        while index < tokens.count, index - start <= 4 {
            if PythonDictation.phrase(tokens, at: index, in: comparisons, longest: 6) != nil {
                return index > start
            }
            let word = Token.word(tokens[index])
            if word.isEmpty || stringOpeners.contains(word) || keywords[word] != nil {
                return false
            }
            index += 1
        }
        return false
    }

    /// A token that begins a value: a quote or a figure.
    private static func startsValue(_ token: String) -> Bool {
        stringOpeners.contains(Token.word(token)) || SpokenNumbers.isFigure(token)
    }

    /// A single-quoted literal from the words spoken inside it. `%` is said
    /// "percent" and binds to its neighbours, which is what a `LIKE` pattern
    /// wants: "percent war percent" is `'%war%'`.
    static func literal(_ words: [String]) -> String {
        let marker = "\u{E000}"
        let marked = words.map { Token.word($0) == "percent" ? marker : $0 }
        let python = PythonDictation.literal(marked, opener: "\"", closed: true)
        var body = String(python.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: " " + marker, with: marker)
            .replacingOccurrences(of: marker + " ", with: marker)
            .replacingOccurrences(of: marker, with: "%")
        body = body.replacingOccurrences(of: "'", with: "''")
        return "'" + body + "'"
    }

    private static func lexCode(_ tokens: [String]) -> [Unit] {
        var units: [Unit] = []
        var index = 0
        while index < tokens.count {
            if let (_, length) = PythonDictation.phrase(tokens, at: index,
                                                        in: PythonDictation.lineBreaks, longest: 2) {
                // "where age greater than 10 next. Next line" — a false start.
                if units.last == .word("next") { units.removeLast() }
                units.append(.lineBreak)
                index += length
                continue
            }
            if let (phrase, length) = PythonDictation.phrase(
                tokens, at: index, in: commandPhrases, longest: longestCommand) {
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

    private static func tokenUnits(_ token: String, next: String?) -> [Unit] {
        let parts = Token.parts(of: token)
        if parts.core.isEmpty {
            let symbol = parts.leading + parts.trailing
            switch symbol {
            case "=", "==": return [.op("=")]
            case "<>", "!=": return [.op("<>")]
            case "<", ">", "<=", ">=", "+", "-", "/": return [.op(symbol)]
            case "*": return [.star]
            default: return symbol.compactMap(symbolUnit)
            }
        }
        var units = parts.leading.compactMap(symbolUnit)
        // "employee.name" arrives as one token.
        for (position, piece) in CodeLayout.figure(parts.core).split(
            separator: ".", omittingEmptySubsequences: false).enumerated() {
            if position > 0 { units.append(.dot) }
            guard !piece.isEmpty else { continue }
            units.append(piece.allSatisfy(\.isNumber)
                         ? .number(String(piece)) : .word(piece.lowercased()))
        }
        units.append(contentsOf: trailingUnits(token, next: next, afterCommand: false))
        return units
    }

    private static func symbolUnit(_ character: Character) -> Unit? {
        switch character {
        case "(": return .open
        case ")": return .close
        case "*": return .star
        case ";": return .end
        case ",": return .comma(hard: false)
        default: return nil
        }
    }

    /// What the punctuation hanging off a token means: the rules
    /// `PythonDictation` measured. A comma between two figures was spoken; any
    /// other is a pause. A full stop is a dot only before a lowercase word.
    private static func trailingUnits(_ token: String, next: String?, afterCommand: Bool) -> [Unit] {
        let parts = Token.parts(of: token)
        let isFigure = !parts.core.isEmpty && parts.core.allSatisfy(\.isNumber)
            && next.map(SpokenNumbers.isFigure) == true
        var units: [Unit] = []
        for character in parts.trailing {
            switch character {
            case ",": units.append(.comma(hard: isFigure && !afterCommand))
            case "(": units.append(.open)
            case ")": units.append(.close)
            case "*": units.append(.star)
            case ";": units.append(.end)
            case ".":
                if parts.trailing == ".", next?.first?.isLowercase == true { units.append(.dot) }
            default: break
            }
        }
        return units
    }

    // MARK: - Statements

    /// Splits the dictation where a statement ends: at "semicolon", or where
    /// the next one plainly starts.
    static func statements(_ units: [Unit]) -> [[Unit]] {
        var result: [[Unit]] = [[]]
        var depth = 0
        for unit in units {
            if case .keyword(let keyword) = unit, depth == 0, statementStarts.contains(keyword) {
                let current = result[result.count - 1]
                if current.contains(where: { $0 != .lineBreak }),
                   !continues(current, with: keyword) {
                    result.append([])
                }
            }
            switch unit {
            case .open: depth += 1
            case .close: depth = max(0, depth - 1)
            default: break
            }
            result[result.count - 1].append(unit)
            if unit == .end {
                result.append([])
                depth = 0
            }
        }
        return result.filter { $0.contains { $0 != .lineBreak } }
    }

    /// `INSERT INTO … SELECT`, `… UNION SELECT`, `ALTER TABLE … DROP`.
    private static func continues(_ statement: [Unit], with keyword: String) -> Bool {
        let first = firstKeyword(statement)
        let last = statement.last { if case .keyword = $0 { return true } else { return false } }
        if keyword == "SELECT" {
            // `INSERT INTO t SELECT …` — but not once the rows were given.
            if ["INSERT INTO", "INSERT", "CREATE TABLE", "CREATE"].contains(first),
               !statement.contains(.keyword("VALUES")) { return true }
            if case .keyword(let previous)? = last, previous.hasPrefix("UNION") { return true }
        }
        return keyword.hasPrefix("DROP") && (first ?? "").hasPrefix("ALTER")
    }

    private static func firstKeyword(_ units: [Unit]) -> String? {
        for unit in units {
            if case .keyword(let keyword) = unit { return keyword }
            if unit != .lineBreak { return nil }
        }
        return nil
    }

    enum Kind { case select, insert, update, delete, create, alter, other }

    private static func kind(of units: [Unit]) -> Kind {
        switch firstKeyword(units) {
        case "SELECT"?: return .select
        case "INSERT INTO"?, "INSERT"?: return .insert
        case "UPDATE"?: return .update
        case "DELETE FROM"?, "DELETE"?: return .delete
        case "CREATE TABLE"?, "CREATE"?: return .create
        case "ALTER TABLE"?, "ALTER"?: return .alter
        default: return .other
        }
    }

    // MARK: - Shaping: words to names, types and keywords

    static func shape(_ units: [Unit], naming: Naming) -> [Unit] {
        let statementKind = kind(of: units)
        let defining = statementKind == .create || statementKind == .alter
        var out: [Unit] = []
        var index = 0
        while index < units.count {
            let unit = units[index]
            guard case .word = unit else {
                // "age int" is heard "age in" (measured for Python). Where a
                // column's type goes, `IN` can only be that.
                if unit == .keyword("IN"), defining, case .name? = out.last,
                   !startsValue(units[safe: index + 1]) {
                    out.append(.type("INTEGER"))
                } else {
                    out.append(unit)
                }
                index += 1
                continue
            }
            var run: [String] = []
            while case .word(let word)? = units[safe: index] {
                run.append(word)
                index += 1
            }
            resolve(run, into: &out, after: units[safe: index], kind: statementKind, naming: naming)
        }
        return out
    }

    /// A run of plain words: names, and the words that are SQL only here.
    private static func resolve(_ run: [String], into out: inout [Unit], after: Unit?,
                                kind: Kind, naming: Naming) {
        let defining = kind == .create || kind == .alter
        var words: [String] = []
        for word in run where word != "underscore" {
            // "var char"
            if word == "char", words.last == "var" {
                words[words.count - 1] = "varchar"
            } else {
                words.append(word)
            }
        }
        // "create table project project id integer": no pause after the
        // table's name, so its first word is the table.
        if out.last == .keyword("CREATE TABLE"), words.count >= 3,
           typeWords[words.last!] != nil {
            out.append(.name(style([words.removeFirst()], table: true, naming: naming)))
        }
        // "references department dept code": the table, then its column.
        if out.last == .keyword("REFERENCES"), words.count >= 2 {
            out.append(.name(style([words.removeFirst()], table: true, naming: naming)))
        }
        // A column and its type: "project name varchar", "start date date".
        var columnType: String?
        if defining, words.count >= 2, !introducesTable(out.last),
           let type = typeWords[words.last!] {
            columnType = type
            words.removeLast()
        }

        let alias = out.last == .keyword("AS")
        var pending: [String] = []
        func flush(atEnd: Bool) {
            guard !pending.isEmpty else { return }
            let table = introducesTable(out.last) || (atEnd && after == .dot)
            out.append(.name(style(pending, table: table, naming: naming)))
            pending = []
        }

        var index = 0
        while index < words.count {
            let word = words[index]
            let more = index + 1 < words.count
            if !defining, !alias, let function = functions[word],
               more || startsOperand(after), !(pending.isEmpty && out.last == .dot) {
                flush(atEnd: false)
                out.append(.function(function))
                index += 1
                if words[safe: index] == "of" { index += 1 }   // "count of students"
                continue
            }
            if word == "all", pending.isEmpty, allowsStar(out.last) {
                out.append(.star)
            } else if word == "set", kind == .update,
                      !(pending.isEmpty && out.last == .keyword("UPDATE")) {
                flush(atEnd: false)
                out.append(.keyword("SET"))
            } else if word == "value", kind == .insert {
                flush(atEnd: false)
                out.append(.keyword("VALUES"))
            } else if ["desk", "disk"].contains(word), lastKeyword(out) == "ORDER BY",
                      !pending.isEmpty || isName(out.last) {
                // "desc" said the way it is spelled.
                flush(atEnd: false)
                out.append(.keyword("DESC"))
            } else if word == "table", pending.isEmpty, case .keyword(let keyword)? = out.last,
                      ["CREATE", "ALTER", "DROP"].contains(keyword) {
                out[out.count - 1] = .keyword(keyword + " TABLE")
            } else if let type = strictTypes[word] {
                flush(atEnd: false)
                out.append(.type(type))
            } else {
                pending.append(word)
            }
            index += 1
        }
        flush(atEnd: true)
        if let columnType { out.append(.type(columnType)) }
    }

    static func style(_ words: [String], table: Bool, naming: Naming) -> String {
        switch naming {
        case .snakeCase:
            return words.map { $0.lowercased() }.joined(separator: "_")
        case .cambridge:
            if table { return words.map { $0.uppercased() }.joined(separator: "_") }
            return words.map { word in
                word == "id" ? "ID" : word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined()
        }
    }

    private static func introducesTable(_ unit: Unit?) -> Bool {
        if case .keyword(let keyword)? = unit { return tableIntroducers.contains(keyword) }
        return false
    }

    private static func allowsStar(_ unit: Unit?) -> Bool {
        switch unit {
        case .keyword("SELECT")?, .keyword("DISTINCT")?, .function?, .open?: return true
        default: return false
        }
    }

    private static func lastKeyword(_ units: [Unit]) -> String? {
        for unit in units.reversed() {
            if case .keyword(let keyword) = unit { return keyword }
        }
        return nil
    }

    private static func isName(_ unit: Unit?) -> Bool {
        if case .name? = unit { return true }
        return false
    }

    // MARK: - Structure: brackets, commas, the semicolon

    /// Why a bracket is open, which decides when it closes by itself.
    private enum Opened: Equatable {
        /// Said aloud: closes when "close" is said, or at the end.
        case spoken
        /// `COUNT(*)`, `VARCHAR(30)`, `PRIMARY KEY (id)`: one value.
        case operand
        /// `IN ('a', 'b')`, `INSERT INTO t (a, b)`: until the next keyword.
        case list
        /// `VALUES (…)`, a `CREATE TABLE` column list: to the end.
        case statement
    }

    static func structure(_ input: [Unit]) -> [Unit] {
        var units = input
        while units.last == .lineBreak { units.removeLast() }
        var out: [Unit] = []
        var stack: [Opened] = []

        func open(_ reason: Opened, _ unit: Unit = .open) {
            out.append(unit)
            stack.append(reason)
        }
        func close(while test: (Opened) -> Bool) {
            while let top = stack.last, test(top) {
                stack.removeLast()
                out.append(.close)
            }
        }

        var index = 0
        while index < units.count {
            let unit = units[index]
            let adjacent = units[safe: index + 1]
            // What comes next, looking past a "next line": a break never
            // changes what a comma or a bracket means.
            let next = units[(index + 1)...].first { $0 != .lineBreak }
            let previous = index > 0 ? units[index - 1] : nil
            switch unit {
            case .keyword(let keyword):
                if keyword != "DISTINCT" { close { $0 == .operand } }
                if !["NULL", "TRUE", "FALSE", "DISTINCT"].contains(keyword) {
                    close { $0 == .list }
                }
                out.append(unit)
                if ["PRIMARY KEY", "FOREIGN KEY"].contains(keyword), isName(next) {
                    open(.operand)
                } else if ["IN", "NOT IN"].contains(keyword), next != .open, startsValue(next) {
                    open(.list)
                } else if keyword == "VALUES", next != .open, startsValue(next) {
                    open(.statement)
                }

            case .function:
                out.append(unit)
                if next != .open, startsOperand(next) { open(.operand) }

            case .type(let type):
                out.append(unit)
                if ["VARCHAR", "CHAR", "DECIMAL"].contains(type), case .number? = next {
                    open(.operand)
                }

            case .name:
                out.append(unit)
                if case .keyword(let keyword)? = previous, keyword.hasPrefix("CREATE") {
                    // The table's name: its column list follows, whether
                    // opened by a bracket, a pause, or nothing at all.
                    if case .comma? = adjacent {
                        open(.statement, .columns)
                        index += 2
                        continue
                    }
                    if isName(next) { open(.statement, .columns) }
                } else if case .keyword(let keyword)? = previous,
                          ["INSERT INTO", "INTO"].contains(keyword), case .comma? = adjacent {
                    // "insert into employee, employee id, name, values …"
                    open(.list)
                    index += 2
                    continue
                } else if previous == .keyword("REFERENCES"), isName(next) {
                    open(.operand)
                } else if next != .dot {
                    close { $0 == .operand }
                }

            case .number, .text, .star:
                out.append(unit)
                close { $0 == .operand }

            case .open:
                if isName(previous), case .keyword(let keyword)? = units[safe: index - 2],
                   keyword.hasPrefix("CREATE") {
                    open(.spoken, .columns)
                } else {
                    open(.spoken)
                }

            case .close:
                // "close" with nothing open was never a bracket.
                if !stack.isEmpty {
                    stack.removeLast()
                    out.append(.close)
                }
                close { $0 == .operand }

            case .comma(let hard):
                close { $0 == .operand }
                let last = out.last
                let separates = hard || isValueEnd(last) || endsListItem(last)
                if separates, startsValue(next) || startsConstraint(next), !isComma(last) {
                    out.append(.comma(hard: true))
                }

            case .end:
                close { _ in true }
                out.append(.end)

            default:
                out.append(unit)
            }
            index += 1
        }
        close { _ in true }
        // Only a statement ends with `;`. Words that start with no statement
        // keyword continue one already in the editor — more columns inside an
        // open column list, another condition — and a `;` would end it early.
        if let first = firstKeyword(out), statementStarts.contains(first), out.last != .end {
            out.append(.end)
        }
        return out
    }

    private static func startsValue(_ unit: Unit?) -> Bool {
        switch unit {
        case .name?, .word?, .number?, .text?, .star?, .function?, .open?: return true
        case .keyword(let keyword)?: return ["NULL", "TRUE", "FALSE"].contains(keyword)
        case .op("-")?: return true
        default: return false
        }
    }

    private static func startsOperand(_ unit: Unit?) -> Bool {
        switch unit {
        case .name?, .word?, .number?, .text?, .star?, .function?: return true
        case .keyword("DISTINCT")?: return true
        default: return false
        }
    }

    private static func isValueEnd(_ unit: Unit?) -> Bool {
        switch unit {
        case .name?, .number?, .text?, .star?, .close?, .type?: return true
        default: return false
        }
    }

    /// Keywords that can end one item of a list: `ORDER BY a ASC, b`,
    /// `id INTEGER PRIMARY KEY, name`.
    private static func endsListItem(_ unit: Unit?) -> Bool {
        guard case .keyword(let keyword)? = unit else { return false }
        return ["ASC", "DESC", "NULL", "NOT NULL", "PRIMARY KEY", "UNIQUE", "TRUE", "FALSE"]
            .contains(keyword)
    }

    private static func startsConstraint(_ unit: Unit?) -> Bool {
        guard case .keyword(let keyword)? = unit else { return false }
        return ["PRIMARY KEY", "FOREIGN KEY", "UNIQUE"].contains(keyword)
    }

    private static func isComma(_ unit: Unit?) -> Bool {
        if case .comma? = unit { return true }
        return false
    }

    // MARK: - Layout: statements to lines

    /// A clause keyword at the top level starts a line; a `CREATE TABLE`
    /// column list puts each column on its own line and the closer on the
    /// last, as Trace Table's model answers are written.
    static func layout(_ units: [Unit]) -> [[Unit]] {
        var rows: [[Unit]] = [[]]
        var depth = 0
        var columnsDepth: Int?
        func breakLine() {
            if !rows[rows.count - 1].isEmpty { rows.append([]) }
        }
        func append(_ unit: Unit) { rows[rows.count - 1].append(unit) }

        for unit in units {
            switch unit {
            case .lineBreak:
                breakLine()
            case .keyword(let keyword) where depth == 0 && clauseStarts.contains(keyword):
                breakLine()
                append(unit)
            case .columns:
                append(unit)
                depth += 1
                columnsDepth = depth
                breakLine()
            case .open:
                depth += 1
                append(unit)
            case .close:
                if depth == columnsDepth {
                    breakLine()
                    columnsDepth = nil
                }
                depth = max(0, depth - 1)
                append(unit)
            case .comma where depth == columnsDepth:
                append(unit)
                breakLine()
            default:
                append(unit)
            }
        }
        return rows.filter { !$0.isEmpty }
    }

    // MARK: - Rendering

    static func render(_ units: [Unit]) -> String {
        var text = ""
        var previous: Unit?
        for unit in units {
            var space = previous != nil
            let piece: String
            switch unit {
            case .word(let word): piece = word
            case .keyword(let keyword): piece = keyword
            case .function(let function): piece = function
            case .type(let type): piece = type
            case .name(let name): piece = name
            case .number(let number): piece = number
            case .text(let literal): piece = literal
            case .op(let op): piece = op
            case .star: piece = "*"
            case .open, .columns:
                piece = "("
                switch previous {
                case .function?, .type?: space = false
                default: break
                }
            case .close: piece = ")"; space = false
            case .comma: piece = ","; space = false
            case .dot: piece = "."; space = false
            case .end: piece = ";"; space = false
            case .lineBreak: continue
            }
            switch previous {
            case .open?, .columns?, .dot?: space = false
            default: break
            }
            if space { text += " " }
            text += piece
            previous = unit
        }
        return text
    }
}
