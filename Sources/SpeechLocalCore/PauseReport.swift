import Foundation

/// The silence before each break the recognizer made, for doctor.log.
///
/// Stage 9 of the Build Order: a pause mid-sentence gets a full stop ("…two,
/// actually three. Logs."), and two rules and the on-device model all scored
/// about a coin toss at telling that from a real sentence end. The recognizer
/// knows something the text does not — how long the pause was. This records
/// it at every segment boundary, so real dictations can show whether pause
/// length separates the two before any rule is built on it.
public enum PauseReport {
    /// One entry per boundary: the last word before it, with its punctuation,
    /// then the gap in milliseconds. `"three.|420 Logs|80 and"`.
    public static func describe(_ segments: [TimedSegment]) -> String {
        guard segments.count > 1 else { return "" }
        var entries: [String] = []
        for (previous, next) in zip(segments, segments.dropFirst()) {
            let last = previous.text.split(separator: " ").last.map(String.init) ?? ""
            let first = next.text.split(separator: " ").first.map(String.init) ?? ""
            let gap = max(0, Int(((next.start - previous.end) * 1000).rounded()))
            entries.append("\(last)|\(gap) \(first)")
        }
        return entries.joined(separator: "  ")
    }
}
