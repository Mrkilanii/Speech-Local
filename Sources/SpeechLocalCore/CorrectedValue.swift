import Foundation

/// Keeps the value a speaker corrected to, and drops the one they corrected.
///
///     "let's do coffee at 2 actually 3"      ->  "let's do coffee at 3"
///     "Let's meet Monday, no actually Tuesday."  ->  "Let's meet Tuesday."
///
/// Decision 01 recorded that rules cannot resolve a spoken self-correction,
/// and in general they cannot: "I mean" followed by a restated clause needs
/// meaning. This handles only the one shape that does not — **a value, a
/// correcting word, and another value of the same kind**. Every instance of it
/// in the dictation log ("116, no, 125", "5280, wait, 539", "24, I mean, 8")
/// was a real correction.
///
/// Each condition is there to stop a real sentence matching:
///
/// 1. **Both values are the same kind** — a figure (`2`, `3:30`, `4.5`, `3pm`),
///    a weekday, or a month. "Monday actually 3" is not a correction of Monday.
/// 2. **The first value does not end a sentence.** Its punctuation is nothing
///    or a comma, so "It was 2. Actually 3 people came." is two statements.
/// 3. **The connector is short and explicit**: "i mean", or one or two of
///    "actually", "no", "sorry", "wait", each carrying at most a comma.
///    "I actually enjoyed the movie" has no value on either side.
/// 4. **The second value has nothing in front of it**, so a quote or bracket
///    opening after the connector is not swallowed.
///
/// A figure is digits or a single number word. The recognizer writes small
/// numbers as words — Omar's "at 2, actually 3" arrived as "At two, actually
/// three." (27 Sep) and was left alone when figures were digits only, because
/// `SpokenNumbers` runs later, in cleanup. The kept word becomes a digit there.
/// A grouped figure like "1,000" is left alone: its comma is ambiguous with a
/// pause.
///
/// **"to" and "too" count as a first value only when a figure follows the
/// connector.** "two" is heard as "to" often enough that `SpokenNumbers` keeps
/// an exception table for it, and "like to actually three" (same dictation)
/// meant "like two, actually three". Nothing else reads "to actually 3".
///
/// **"May" is a month only when capitalised.** Lowercase "may" is the verb —
/// "we may, actually, may not" is not a date — and the recognizer capitalises
/// the month. Every other weekday and month name matches in any case.
///
/// The replacement keeps the first value's leading punctuation and the second
/// value's trailing punctuation, so "(2 actually 3)" becomes "(3)". After a
/// replacement the same position is scanned again, so a chain ("1 actually 2
/// actually 3") collapses to its last value.
public enum CorrectedValue {
    enum Kind: Equatable {
        case figure, weekday, month
    }

    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]

    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Words that may stand alone, or in pairs, between the two values.
    static let connectors: Set<String> = ["actually", "no", "sorry", "wait"]

    public static func apply(_ text: String) -> String {
        var tokens = Token.split(text)
        var changed = false
        var index = 0
        while index < tokens.count {
            if let end = correction(in: tokens, at: index) {
                let first = Token.parts(of: tokens[index])
                let last = Token.parts(of: tokens[end])
                tokens.replaceSubrange(index...end,
                                       with: [first.leading + last.core + last.trailing])
                changed = true
                // Same index again: the merged token may itself be corrected.
                continue
            }
            index += 1
        }
        // Nothing corrected means nothing touched, whitespace included.
        guard changed else { return text }
        return Token.join(tokens)
    }

    /// If a correction starts at `index`, the index of the value it ends on.
    private static func correction(in tokens: [String], at index: Int) -> Int? {
        let first = Token.parts(of: tokens[index])
        let heardAsTwo = ["to", "too"].contains(first.core.lowercased())
        guard first.trailing.isEmpty || first.trailing == ",",
              let kind = heardAsTwo ? .figure : kind(of: first.core)
        else { return nil }

        for connectorLength in connectorLengths(in: tokens, after: index) {
            let end = index + connectorLength + 1
            guard let candidate = tokens[safe: end] else { continue }
            let second = Token.parts(of: candidate)
            if second.leading.isEmpty, self.kind(of: second.core) == kind { return end }
        }
        return nil
    }

    /// How many tokens after `index` could form a connector, shortest first.
    private static func connectorLengths(in tokens: [String], after index: Int) -> [Int] {
        func word(_ offset: Int) -> String? {
            guard let token = tokens[safe: index + offset] else { return nil }
            let parts = Token.parts(of: token)
            guard parts.leading.isEmpty, parts.trailing.isEmpty || parts.trailing == ","
            else { return nil }
            return parts.core.lowercased()
        }

        if word(1) == "i", word(2) == "mean" { return [2] }
        guard let one = word(1), connectors.contains(one) else { return [] }
        if let two = word(2), connectors.contains(two) { return [1, 2] }
        return [1]
    }

    static func kind(of core: String) -> Kind? {
        if core.wholeMatch(of: /[0-9]+([:.][0-9]+)?(am|pm)?/.ignoresCase()) != nil {
            return .figure
        }
        let lower = core.lowercased()
        let parts = lower.split(separator: "-").map(String.init)   // "twenty-three"
        if !parts.isEmpty, parts.allSatisfy({ SpokenNumbers.units[$0] != nil
            || SpokenNumbers.tens[$0] != nil || $0 == "hundred" }) {
            return .figure
        }
        if weekdays.contains(lower) { return .weekday }
        // The verb "may" is far more common than the month in speech.
        if lower == "may" { return core.first?.isUppercase == true ? .month : nil }
        if months.contains(lower) { return .month }
        return nil
    }
}
