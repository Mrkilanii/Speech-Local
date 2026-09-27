import Foundation

/// Wispr Flow's "Backtrack", in the shapes rules can decide (decision 11).
///
/// Order matters: a discourse marker comes out first, so "2, like, actually
/// 3" is a value swap; "scratch that" runs before the swap so a scratched
/// sentence cannot leave half a correction behind.
///
/// English only, and never in code mode, where "actually" or "no" can be an
/// identifier — the caller decides both.
public enum Backtrack {
    public static func apply(_ text: String) -> String {
        CorrectedValue.apply(ScratchThat.apply(DiscourseFillers.apply(text)))
    }
}
