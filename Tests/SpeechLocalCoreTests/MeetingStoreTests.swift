import Testing
import Foundation
@testable import SpeechLocalCore

private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("speechlocal-meetings-\(UUID().uuidString)")
}

private func meeting(_ title: String, minutesAgo: Double = 0) -> Meeting {
    Meeting(startedAt: Date().addingTimeInterval(-minutesAgo * 60),
            endedAt: Date().addingTimeInterval(-minutesAgo * 60 + 600),
            title: title, notes: "what I typed",
            transcript: "what was said", summary: "what the model wrote")
}

// MARK: - Store

@Test func aMeetingSurvivesAReload() async throws {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = MeetingStore(directory: directory)
    let original = meeting("Standup")
    await store.save(original)

    let reloaded = await MeetingStore(directory: directory).all()
    #expect(reloaded.count == 1)
    let recovered = try #require(reloaded.first)
    #expect(recovered.id == original.id)
    #expect(recovered.title == original.title)
    #expect(recovered.notes == original.notes)
    #expect(recovered.transcript == original.transcript)
    #expect(recovered.summary == original.summary)
    // ISO-8601 stores whole seconds, so a timestamp round-trips to the second
    // and no closer. That is precision this never needed.
    #expect(abs(recovered.startedAt.timeIntervalSince(original.startedAt)) < 1)
}

@Test func meetingsComeBackNewestFirst() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)

    await store.save(meeting("Oldest", minutesAgo: 120))
    await store.save(meeting("Newest", minutesAgo: 1))
    await store.save(meeting("Middle", minutesAgo: 60))

    #expect(await store.all().map(\.title) == ["Newest", "Middle", "Oldest"])
}

@Test func savingTwiceUpdatesRatherThanDuplicates() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)

    var subject = meeting("Draft")
    await store.save(subject)
    subject.summary = "written later"
    await store.save(subject)

    let all = await store.all()
    #expect(all.count == 1, "one meeting, one file")
    #expect(all.first?.summary == "written later")
}

@Test func aMeetingFileIsNotWorldReadable() async throws {
    // It holds everything said in a room, so it gets what history gets.
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    let subject = meeting("Private")
    await store.save(subject)

    let file = directory.appendingPathComponent("\(subject.id.uuidString).json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
}

@Test func clearingLeavesNothingBehind() async {
    let directory = tempDirectory()
    let store = MeetingStore(directory: directory)
    await store.save(meeting("Gone"))
    await store.clear()

    #expect(await store.all().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.path),
            "not even an empty folder where the meetings were")
}

@Test func searchLooksAtEverythingIncludingTheTranscript() async {
    let directory = tempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = MeetingStore(directory: directory)
    await store.save(meeting("Standup"))

    #expect(await store.search("standup").count == 1)
    #expect(await store.search("what was said").count == 1)
    #expect(await store.search("").count == 1)
    #expect(await store.search("nothing like this").isEmpty)
}

@Test func aMeetingWithNoTitleStillHasAName() {
    let untitled = Meeting(startedAt: Date())
    #expect(!untitled.displayTitle.isEmpty)
    #expect(untitled.displayTitle.hasPrefix("Meeting — "))
}
