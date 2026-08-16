import Testing
import Foundation
@testable import FlowLocalCore

private func freshHistory() -> TranscriptHistory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-history-\(UUID().uuidString).json")
    return TranscriptHistory(storeURL: url)
}

private func entry(_ text: String, mode: CleanupMode = .lightTouch,
                   app: String? = nil) -> TranscriptEntry {
    TranscriptEntry(raw: text, cleaned: text, mode: mode, appName: app)
}

// MARK: - Recording

@Test func recordsAndReturnsNewestFirst() async {
    let history = freshHistory()
    await history.record(entry("first"))
    await history.record(entry("second"))
    let all = await history.all()
    #expect(all.count == 2)
    #expect(all.first?.cleaned == "second", "newest must come first")
}

@Test func emptyHistoryIsEmpty() async {
    #expect(await freshHistory().all().isEmpty)
}

// MARK: - The cap

@Test func discardsOldestBeyondTheCap() async {
    // Unbounded history of everything a person says is not acceptable, so the
    // store is capped rather than growing forever.
    let history = freshHistory()
    for index in 0..<(TranscriptHistory.maximumEntries + 25) {
        await history.record(entry("entry \(index)"))
    }
    let all = await history.all()
    #expect(all.count == TranscriptHistory.maximumEntries)
    #expect(all.first?.cleaned == "entry \(TranscriptHistory.maximumEntries + 24)")
    #expect(!all.contains { $0.cleaned == "entry 0" }, "oldest must be discarded")
}

// MARK: - Search

@Test func searchMatchesCleanedText() async {
    let history = freshHistory()
    await history.record(entry("ship it on monday"))
    await history.record(entry("call the client"))
    #expect(await history.search("monday").count == 1)
}

@Test func searchIsCaseInsensitive() async {
    let history = freshHistory()
    await history.record(entry("Ship It On Monday"))
    #expect(await history.search("MONDAY").count == 1)
}

@Test func searchMatchesTheAppName() async {
    let history = freshHistory()
    await history.record(entry("hello", app: "Terminal"))
    await history.record(entry("hello", app: "Safari"))
    #expect(await history.search("terminal").count == 1)
}

@Test func emptySearchReturnsEverything() async {
    let history = freshHistory()
    await history.record(entry("one"))
    await history.record(entry("two"))
    #expect(await history.search("   ").count == 2)
}

@Test func searchMatchesRawWhenCleanupChangedIt() async {
    // Useful when hunting for what was actually heard rather than written.
    let history = freshHistory()
    await history.record(TranscriptEntry(
        raw: "um the tip is ready", cleaned: "The ship is ready.", mode: .lightTouch))
    #expect(await history.search("tip").count == 1)
}

// MARK: - Deletion

@Test func deletesASingleEntry() async {
    let history = freshHistory()
    let target = entry("delete me")
    await history.record(entry("keep me"))
    await history.record(target)
    await history.delete(id: target.id)
    let all = await history.all()
    #expect(all.count == 1)
    #expect(all.first?.cleaned == "keep me")
}

@Test func clearRemovesEverythingAndTheFile() async {
    // Turning history off must destroy what was captured, not merely hide it.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-clear-\(UUID().uuidString).json")
    let history = TranscriptHistory(storeURL: url)
    await history.record(entry("sensitive thing"))
    #expect(FileManager.default.fileExists(atPath: url.path))

    await history.clear()
    #expect(await history.count() == 0)
    #expect(!FileManager.default.fileExists(atPath: url.path),
            "the file itself must be removed, not just emptied")
}

// MARK: - Persistence

@Test func historySurvivesReload() async {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-persist-\(UUID().uuidString).json")
    let first = TranscriptHistory(storeURL: url)
    await first.record(TranscriptEntry(
        raw: "raw text", cleaned: "Clean text.", mode: .fullRewrite, appName: "Notes"))

    let second = TranscriptHistory(storeURL: url)
    let all = await second.all()
    #expect(all.count == 1)
    #expect(all.first?.cleaned == "Clean text.")
    #expect(all.first?.mode == .fullRewrite)
    #expect(all.first?.appName == "Notes")
}

@Test func historyFileIsOwnerReadableOnly() async {
    // It contains everything the user has dictated.
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-perm-\(UUID().uuidString).json")
    let history = TranscriptHistory(storeURL: url)
    await history.record(entry("private"))

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let permissions = attributes?[.posixPermissions] as? NSNumber
    #expect(permissions?.int16Value == 0o600)
}

@Test func corruptFileFallsBackToEmpty() async {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("flowlocal-corrupt-\(UUID().uuidString).json")
    try? "not json at all".write(to: url, atomically: true, encoding: .utf8)
    #expect(await TranscriptHistory(storeURL: url).all().isEmpty)
}
