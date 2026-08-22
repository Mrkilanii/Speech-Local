import Foundation

/// One recorded meeting and everything derived from it.
public struct Meeting: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// What the user called it, or a date if they never said.
    public var title: String
    /// What the user typed while it was running. Their words, not the model's.
    public var notes: String
    public var transcript: String
    /// Generated. Kept apart from `notes` everywhere, including on disk.
    public var summary: String
    /// Where it was filed in the vault, if it was.
    public var filedAt: String?

    public init(id: UUID = UUID(), startedAt: Date = Date(), endedAt: Date? = nil,
                title: String = "", notes: String = "", transcript: String = "",
                summary: String = "", filedAt: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.notes = notes
        self.transcript = transcript
        self.summary = summary
        self.filedAt = filedAt
    }

    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    /// The title, or something usable when there is none.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM, HH:mm"
        return "Meeting — \(formatter.string(from: startedAt))"
    }

    public func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        return [title, notes, transcript, summary]
            .contains { $0.lowercased().contains(needle) }
    }
}

/// Meetings on disk, one file each.
///
/// Follows `TranscriptHistory` — atomic write, `0600`, ISO-8601 — with one
/// difference: a file per meeting rather than a single capped array. An hour of
/// transcript is around 60 KB, and rewriting every meeting to save one of them
/// gets worse the longer the app is used.
///
/// This is the same kind of privacy surface as transcript history: it holds
/// everything said in a room. Turning it off deletes what was stored rather
/// than hiding it.
public actor MeetingStore {
    private let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SpeechLocal/meetings")
    }

    public func save(_ meeting: Meeting) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(meeting) else { return }
        let url = file(for: meeting.id)
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Newest first.
    public func all() -> [Meeting] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Meeting.self, from: Data(contentsOf: $0)) }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func search(_ query: String) -> [Meeting] {
        all().filter { $0.matches(query) }
    }

    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Removes the directory, not just its contents — leaving an empty folder
    /// where someone's meetings were is the sort of residue this promise is
    /// meant to exclude.
    public func clear() {
        try? FileManager.default.removeItem(at: directory)
    }

    public func count() -> Int { all().count }

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
