import Foundation

/// Indentation for the code dictations whose blocks are brackets rather than
/// Python's colons: SQL's column lists (`(`) and TypeScript's braces (`{`).
///
/// Same reasoning as `PythonDictation.block`: indentation is written into the
/// paste as text, never keyed, because what an editor does with a synthetic
/// Return cannot be observed from here (decision 10, third run).
enum CodeLayout {
    /// The lines as one piece of text. Each line after a break sits at the
    /// depth of the brackets still open above it, one level less when it
    /// starts with the closer. Levels are counted from the caret line's own
    /// indentation, and one deeper when the caret line ends with an opener.
    ///
    /// `mergesCloser`: a first line such as `} else {` typed at a caret that
    /// already follows a `}` drops its own brace instead of doubling it.
    ///
    /// `caseLabels`: lines after a `case …:` or `default:` sit one level in,
    /// until the next label or the brace that closes the `switch`.
    static func block(_ lines: [PythonDictation.Line], caretLine: String?,
                      open: Character, close: Character, unit: String,
                      mergesCloser: Bool = false, caseLabels: Bool = false) -> String {
        let current = caretLine?.split(separator: "\n", omittingEmptySubsequences: false)
            .last.map(String.init) ?? ""
        let base = String(current.prefix { $0 == " " || $0 == "\t" })
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        var level = 0
        var caseLevel: Int?       // the switch body's level, inside a case
        var text = ""
        for (index, line) in lines.enumerated() {
            var body = line.text
            if line.breakBefore {
                if index == 0, trimmed.last == open { level += 1 }
                var own = level - (body.first == close ? 1 : 0)
                if caseLabels {
                    if body.hasPrefix("case ") || body == "default:" {
                        caseLevel = own
                    } else if let switchBody = caseLevel {
                        if own < switchBody { caseLevel = nil } else { own += 1 }
                    }
                }
                text += "\n" + (body.isEmpty ? "" : indent(base, level: own, unit: unit))
            } else if mergesCloser, index == 0, body.hasPrefix(String(close) + " "),
                      trimmed.last == close {
                body = String(body.dropFirst())
            }
            text += body
            level += depthChange(body, open: open, close: close)
        }
        return text
    }

    /// The indentation `level` units away from `base`, which is the caret
    /// line's own. A negative level steps out of `base`: a `}` typed on a body
    /// line belongs one unit left of it.
    static func indent(_ base: String, level: Int, unit: String) -> String {
        guard level < 0 else { return base + String(repeating: unit, count: level) }
        var result = base
        for _ in 0..<(-level) {
            if result.hasSuffix(unit) {
                result.removeLast(unit.count)
            } else if result.hasSuffix("\t") {
                result.removeLast()
            } else {
                var removed = 0
                while removed < unit.count, result.last == " " {
                    result.removeLast()
                    removed += 1
                }
            }
        }
        return result
    }

    /// "44,000" is how the recognizer writes forty-four thousand; in code the
    /// comma would split one value into two.
    static func figure(_ core: String) -> String {
        guard core.range(of: #"^[0-9]{1,3}(,[0-9]{3})+(\.[0-9]+)?$"#,
                         options: .regularExpression) != nil else { return core }
        return core.replacingOccurrences(of: ",", with: "")
    }

    /// Openers minus closers, outside string literals.
    static func depthChange(_ text: String, open: Character, close: Character) -> Int {
        var delta = 0
        var quote: Character?
        var escaped = false
        for character in text {
            if let current = quote {
                if escaped {
                    escaped = false
                } else if character == "\\", current != "'" {
                    escaped = true
                } else if character == current {
                    quote = nil
                }
                continue
            }
            if character == "\"" || character == "'" || character == "`" {
                quote = character
            } else if character == open {
                delta += 1
            } else if character == close {
                delta -= 1
            }
        }
        return delta
    }
}
