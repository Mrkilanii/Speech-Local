import Foundation

/// Turns a dictated enumeration into numbered items.
///
///     "one, do this, two, do that"  ->  "1) do this 2) do that"
///
/// Speaking a list is one of the few things dictation is genuinely bad at: the
/// numbers arrive as ordinary words in a run-on sentence, and the structure the
/// speaker had in their head is gone.
///
/// Three conditions have to hold together, because a bare ascending pair proves
/// nothing — "I need 1 apple and 2 oranges" has the same numbers in the same
/// order:
///
/// 1. **The numbers run 1, 2, 3 from the start.** Years and quantities do not.
/// 2. **Each opens a clause** — nothing before it, or a comma or full stop.
///    That is what "chapter 1, the beginning, chapter 2, the end" fails.
/// 3. **Each is followed by a comma**, which is the recognizer reporting the
///    pause after the number. Saying "1 apple" has no pause and no comma.
///
/// Must run before the comma policy, which is what would remove the evidence
/// in condition 3.
enum SpokenList {
    /// At least this many items before a run of numbers is a list.
    static let minimumItems = 2

    static func apply(to tokens: [String]) -> [String] {
        let markers = candidates(in: tokens)
        guard markers.count >= minimumItems,
              markers.map(\.value) == Array(1...markers.count)
        else { return tokens }

        var out = tokens
        for marker in markers {
            let parts = Token.parts(of: out[marker.index])
            out[marker.index] = parts.leading + parts.core + ")"
            // The comma before an item belonged to the sentence it is no
            // longer part of.
            if marker.index > 0 {
                let previous = Token.parts(of: out[marker.index - 1])
                if previous.trailing == "," {
                    out[marker.index - 1] = previous.leading + previous.core
                }
            }
        }
        return out
    }

    private static func candidates(in tokens: [String]) -> [(index: Int, value: Int)] {
        tokens.indices.compactMap { index in
            let parts = Token.parts(of: tokens[index])
            guard parts.trailing == ",", parts.leading.isEmpty,
                  let value = Int(parts.core), parts.core.allSatisfy(\.isNumber),
                  opensClause(tokens, at: index)
            else { return nil }
            return (index: index, value: value)
        }
    }

    private static func opensClause(_ tokens: [String], at index: Int) -> Bool {
        guard index > 0 else { return true }
        guard let last = Token.parts(of: tokens[index - 1]).trailing.last else { return false }
        return last == "," || ".!?".contains(last)
    }
}
