import Foundation

/// What Apple's recognizer writes for spoken code keywords, per language,
/// measured on 27 Sep by feeding 36 `say`-voiced lines through the app's own
/// streaming path (`SpeechLocalStdin --realtime`). Applied to the transcript
/// before a language's rules, so each rule sees the words that were said.
///
/// Every entry is limited to a position where the misheard word cannot mean
/// anything else: "wear" is never a SQL keyword, "Konst" is never a
/// TypeScript identifier at the start of a line. Mishearings into other real
/// words ("agreed" for "greet", "staff" for "star", plurals) are not here —
/// no rule can tell them from what the speaker meant.
enum CodeConfusions {
    static func apply(_ transcript: String, for language: CodeLanguage) -> String {
        var tokens = Token.split(transcript)
        var out: [String] = []
        var index = 0
        func core(_ offset: Int) -> String? { tokens[safe: index + offset].map(Token.word) }
        func trailing(_ offset: Int) -> String { tokens[safe: index + offset].map { Token.parts(of: $0).trailing } ?? "" }
        /// At the start of the dictation or of a spoken line.
        func atLineStart() -> Bool {
            guard let previous = out.last else { return true }
            let word = Token.word(previous)
            return word == "line" || word == "newline" || previous.hasSuffix(".")
        }

        while index < tokens.count {
            let word = Token.word(tokens[index])
            let parts = Token.parts(of: tokens[index])
            // All languages: "comma" heard as "commer".
            if word == "commer" {
                out.append(parts.leading + "comma" + parts.trailing); index += 1; continue
            }
            switch language {
            case .pseudocode:
                // "next i" heard as "next time" — which the shared splitter
                // would otherwise read as a line break, losing the NEXT.
                if word == "next", core(1) == "time" {
                    out.append("next" + trailing(1)); index += 2; continue
                }
                // "ten do" heard as one word, "Tendo".
                if word.hasSuffix("do"), word.count > 2 {
                    let head = String(word.dropLast(2))
                    if SpokenNumbers.units[head] != nil || SpokenNumbers.tens[head] != nil
                        || head.allSatisfy(\.isNumber) {
                        out.append(parts.leading + head); out.append("do" + parts.trailing)
                        index += 1; continue
                    }
                }
                // "as string" heard as "a string" — only straight after a
                // name. After "by ref", "taking" or a comma, "a" is itself a
                // name: "by ref a integer" is the parameter A.
                let introducers: Set<String> = ["ref", "byref", "val", "byval", "taking", "with",
                                                "and", "declare", "procedure", "function"]
                if word == "a" || word == "an", let next = core(1),
                   PseudocodeDictation.types[next] != nil,
                   let previous = out.last, !previous.hasSuffix(","),
                   !introducers.contains(Token.word(previous)) {
                    out.append("as"); index += 1; continue
                }
            case .sql:
                if word == "wear" || word == "ware" {
                    out.append(parts.leading + "where" + parts.trailing); index += 1; continue
                }
                if word == "in", core(1) == "a", core(2) == "join" {
                    out.append("inner"); out.append("join" + trailing(2)); index += 3; continue
                }
                // A pause after a function word: "average, exam".
                if SQLDictation.functions[word] != nil, parts.trailing == "," {
                    out.append(parts.leading + parts.core); index += 1; continue
                }
            case .typescript:
                if atLineStart(), word == "konst" || word == "constant" || word == "const" {
                    out.append(parts.leading + "const" + parts.trailing); index += 1; continue
                }
                if word == "clothes", let next = core(1), ["block", "brace", "bracket", "paren"].contains(next) {
                    out.append("close"); index += 1; continue
                }
                if word == "a", let next = core(1), ["wage", "wait", "weight"].contains(next) {
                    out.append("await" + trailing(1)); index += 2; continue
                }
            case .python:
                break
            }
            out.append(tokens[index])
            index += 1
        }
        tokens = out
        return Token.join(tokens)
    }
}
