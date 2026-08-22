import Foundation

/// Files a finished meeting into the second brain as source material.
///
/// The vault's own rules decide the shape of this, not convenience. From
/// `raw/README.md`: everything in `raw/` is source material, nothing in it may
/// be modified, and **generated summaries do not belong there**. So what gets
/// written is the transcript and what the person typed — both genuinely
/// theirs — and the AI summary stays in the app.
///
/// Promoting a meeting into `wiki/` is the vault's `ingest` skill's job. It
/// catalogues into `wiki/index.md`, follows `_system/page-conventions.md`, and
/// lints. An app writing wiki pages behind its back would produce pages the
/// vault does not know about.
///
/// Three rules, all of them about not damaging someone's knowledge base:
///
/// * Only ever creates files. Never modifies, renames or deletes.
/// * Never overwrites — a name collision takes a suffix.
/// * Never creates the vault. A missing vault means the feature is off, not
///   that a folder should appear in someone's Documents.
public struct VaultWriter: Sendable {
    public enum WriteError: Error, Sendable, Equatable {
        case noVault(String)
        case couldNotWrite(String)
    }

    /// Where meeting sources land, under the vault root.
    public static let subdirectory = "raw/meetings"

    public let root: URL

    public init(root: URL) { self.root = root }

    /// The user's vault, if it is where it usually is. Nil is a valid answer
    /// and means the feature stays off.
    public static func defaultRoot() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/second-brain")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return url
    }

    public var isUsable: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    @discardableResult
    public func write(_ meeting: Meeting) throws -> URL {
        guard isUsable else {
            throw WriteError.noVault("no vault at \(root.path)")
        }
        let folder = root.appendingPathComponent(Self.subdirectory)
        do {
            try FileManager.default.createDirectory(
                at: folder, withIntermediateDirectories: true)
        } catch {
            throw WriteError.couldNotWrite("\(error)")
        }

        let url = availableName(in: folder, for: meeting)
        do {
            try Self.document(for: meeting).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw WriteError.couldNotWrite("\(error)")
        }
        return url
    }

    /// `2026-08-22-standup.md`, and never a name already taken.
    func availableName(in folder: URL, for meeting: Meeting) -> URL {
        let base = "\(Self.day(meeting.startedAt))-\(Self.slug(meeting.displayTitle))"
        var candidate = folder.appendingPathComponent("\(base).md")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base)-\(suffix).md")
            suffix += 1
        }
        return candidate
    }

    static func document(for meeting: Meeting) -> String {
        var out = """
        ---
        title: \(meeting.displayTitle)
        source: SpeechLocal meeting recording
        created: \(day(meeting.startedAt))
        recorded: \(timestamp(meeting.startedAt))
        duration: \(minutes(meeting.duration))
        ---

        # \(meeting.displayTitle)

        """

        let notes = meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty {
            out += "\n## Notes taken during the meeting\n\n\(notes)\n"
        }

        let transcript = meeting.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n## Transcript\n\n"
        out += transcript.isEmpty ? "_Nothing was transcribed._\n" : "\(transcript)\n"
        return out
    }

    /// Filesystem-safe and stable, per the vault's naming convention.
    static func slug(_ title: String) -> String {
        let allowed = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let trimmed = String(collapsed.prefix(60))
        return trimmed.isEmpty ? "meeting" : trimmed
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    static func minutes(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded())
        return total >= 3600
            ? "\(total / 3600)h \((total % 3600) / 60)m"
            : "\(max(1, total / 60))m"
    }
}
