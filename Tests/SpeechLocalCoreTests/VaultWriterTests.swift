import Testing
import Foundation
@testable import SpeechLocalCore

/// A stand-in vault. The real one is never touched by a test.
private func tempVault() -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-vault-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func meeting(title: String = "Design review") -> Meeting {
    Meeting(startedAt: Date(timeIntervalSince1970: 1_787_000_000),
            endedAt: Date(timeIntervalSince1970: 1_787_002_400),
            title: title,
            notes: "- ship on friday\n- ask about the migration",
            transcript: "We agreed to ship on Friday.",
            summary: "GENERATED SUMMARY — must not be filed in raw/")
}

@Test func aMeetingIsFiledAsSourceMaterial() throws {
    let root = tempVault()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = try VaultWriter(root: root).write(meeting())
    #expect(url.path.contains("raw/meetings"))
    #expect(url.lastPathComponent.hasSuffix("-design-review.md"))

    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.contains("title: Design review"))
    #expect(text.contains("source: SpeechLocal meeting recording"))
    #expect(text.contains("ship on friday"), "the user's own notes are source material")
    #expect(text.contains("We agreed to ship on Friday."), "so is the transcript")
}

@Test func theGeneratedSummaryIsNeverFiledInRaw() throws {
    // raw/README.md: "Do not place derived wiki pages, daily journal entries,
    // content drafts, or generated summaries here." Promotion into wiki/ is
    // the vault's own ingest skill's job.
    let root = tempVault()
    defer { try? FileManager.default.removeItem(at: root) }

    let url = try VaultWriter(root: root).write(meeting())
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(!text.contains("GENERATED SUMMARY"))
}

@Test func anExistingFileIsNeverOverwritten() throws {
    let root = tempVault()
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = VaultWriter(root: root)

    let first = try writer.write(meeting())
    let second = try writer.write(meeting())
    #expect(first != second)
    #expect(second.lastPathComponent.contains("-2"))
    // ...and the first is untouched.
    #expect(try String(contentsOf: first, encoding: .utf8).contains("Design review"))
}

@Test func aMissingVaultIsRefusedRatherThanCreated() {
    // A folder appearing in someone's Documents because an app assumed is
    // worse than the feature being off.
    let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-not-a-vault-\(UUID().uuidString)")
    let writer = VaultWriter(root: absent)

    #expect(!writer.isUsable)
    #expect(throws: (any Error).self) { try writer.write(meeting()) }
    #expect(!FileManager.default.fileExists(atPath: absent.path))
}

@Test func nothingOutsideTheMeetingsFolderIsTouched() throws {
    let root = tempVault()
    defer { try? FileManager.default.removeItem(at: root) }

    // A vault with existing source material in it.
    let raw = root.appendingPathComponent("raw")
    try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
    let existing = raw.appendingPathComponent("README.md")
    try "immutable".write(to: existing, atomically: true, encoding: .utf8)

    try VaultWriter(root: root).write(meeting())
    #expect(try String(contentsOf: existing, encoding: .utf8) == "immutable")
}

@Test func titlesBecomeStableFilenames() {
    #expect(VaultWriter.slug("Design review") == "design-review")
    #expect(VaultWriter.slug("Q3 planning — budget & scope!") == "q3-planning-budget-scope")
    #expect(VaultWriter.slug("///") == "meeting", "a name that slugs to nothing still needs one")
    #expect(VaultWriter.slug(String(repeating: "a", count: 200)).count <= 60)
}

@Test func durationReadsAsTime() {
    #expect(VaultWriter.minutes(2_400) == "40m")
    #expect(VaultWriter.minutes(5_400) == "1h 30m")
    #expect(VaultWriter.minutes(20) == "1m", "a short meeting is not zero minutes")
}
