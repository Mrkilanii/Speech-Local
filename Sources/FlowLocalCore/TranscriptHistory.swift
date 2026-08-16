import Foundation

public struct TranscriptEntry: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let date: Date
    /// What the recognizer produced, before cleanup.
    public let raw: String
    /// What was actually inserted.
    public let cleaned: String
    public let mode: CleanupMode
    /// Where it went, when that could be determined.
    public let appName: String?

    public init(
        id: UUID = UUID(),
        date: Date = Date(),
        raw: String,
        cleaned: String,
        mode: CleanupMode,
        appName: String? = nil
    ) {
        self.id = id
        self.date = date
        self.raw = raw
        self.cleaned = cleaned
        self.mode = mode
        self.appName = appName
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return cleaned.lowercased().contains(needle)
            || raw.lowercased().contains(needle)
            || (appName?.lowercased().contains(needle) ?? false)
    }
}

/// A local record of past dictations.
///
/// **This is a privacy surface.** It stores everything the user dictates —
/// which for a dictation app means passwords read aloud, medical details,
/// private messages — in plain JSON under Application Support. Three
/// consequences follow, and they are deliberate:
///
/// * It is **capped**, so it cannot grow into an unbounded archive of someone's
///   speech.
/// * It can be **disabled**, and disabling it deletes what was already stored
///   rather than merely hiding it.
/// * It is never transmitted, and the file is excluded from version control.
public actor TranscriptHistory {
    /// Older entries are discarded past this. Enough to find something from
    /// earlier today; not a permanent archive.
    public static let maximumEntries = 200

    private var entries: [TranscriptEntry] = []
    private let storeURL: URL

    public init(storeURL: URL? = nil) {
        self.storeURL = storeURL ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlowLocal/history.json")
        self.entries = Self.load(from: self.storeURL)
    }

    /// Newest first.
    public func all() -> [TranscriptEntry] { entries }

    public func search(_ query: String) -> [TranscriptEntry] {
        entries.filter { $0.matches(query) }
    }

    public func count() -> Int { entries.count }

    public func record(_ entry: TranscriptEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maximumEntries {
            entries.removeLast(entries.count - Self.maximumEntries)
        }
        save()
    }

    public func delete(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Removes every entry **and the file**. Disabling history must actually
    /// destroy what was captured, not just stop adding to it.
    public func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: storeURL)
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> [TranscriptEntry] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode([TranscriptEntry].self, from: data)
        else { return [] }
        return decoded
    }

    private func save() {
        try? FileManager.default.createDirectory(
            at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        // Written owner-only: this is the user's speech, not world-readable.
        try? data.write(to: storeURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
    }
}
