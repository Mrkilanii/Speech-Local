import Foundation

/// Decides whether the clipboard is copied aside before a paste borrows it.
///
/// Taking a snapshot means reading every item's data eagerly, so the rules are
/// about what is safe and cheap to read and write back:
///
/// * **Files are not restored.** A file URL or a promised file is a reference
///   to something outside the clipboard, not content that can be copied aside.
///   PDFs are skipped with them. Wispr Flow does the same.
/// * **Nothing over 10 MB.** A large image would be read into memory on every
///   dictation, to be put back on a clipboard the user may never paste from.
///
/// A skipped clipboard is simply not restored: the transcript stays on it.
public enum ClipboardSnapshot {
    public enum Decision: Sendable, Equatable {
        case take
        case skip(SkipReason)
    }

    public enum SkipReason: Sendable, Equatable {
        case files
        case tooLarge
    }

    /// Any of these on any item makes the clipboard a file clipboard.
    static let fileTypes: Set<String> = [
        "public.file-url",
        "com.apple.pasteboard.promised-file-url",
        "com.adobe.pdf",
        "NSFilenamesPboardType",
    ]

    /// Inclusive: exactly this many bytes is still taken.
    static let maximumBytes = 10_000_000

    /// - Parameter items: one dictionary per clipboard item, mapping each type
    ///   that has data to its size in bytes.
    public static func decide(items: [[String: Int]]) -> Decision {
        // Files first: a file clipboard is skipped whatever its size, and the
        // reason logged should say why it would be wrong, not merely costly.
        if items.contains(where: { !fileTypes.isDisjoint(with: $0.keys) }) {
            return .skip(.files)
        }
        let total = items.reduce(0) { sum, item in sum + item.values.reduce(0, +) }
        return total > maximumBytes ? .skip(.tooLarge) : .take
    }
}
