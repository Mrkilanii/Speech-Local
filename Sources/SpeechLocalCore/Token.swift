import Foundation

/// A whitespace-delimited token, split into the word inside it and whatever
/// punctuation the recognizer hung off either end.
///
/// Every rewrite in `SpokenNumbers`, `SpokenPunctuation` and `SpelledWords`
/// needs the same three things: match on the bare word, decide from the
/// punctuation, and put the token back together. Splitting it once here is what
/// lets "(twenty-two," come back as "(22,".
enum Token {
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

    /// The bare word, lowercased — what every table in these files is keyed on.
    static func word(_ token: String) -> String {
        parts(of: token).core.lowercased()
    }

    static func split(_ text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func join(_ tokens: [String]) -> String {
        tokens.joined(separator: " ")
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
