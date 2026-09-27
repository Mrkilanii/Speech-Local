import Testing
@testable import SpeechLocalCore

// MARK: - Taken

@Test func anEmptyClipboardIsTaken() {
    #expect(ClipboardSnapshot.decide(items: []) == .take)
}

@Test func aConcealedTextItemIsTaken() {
    // The concealed marker is a type with no data worth counting; it must
    // survive the round trip, not stop the snapshot.
    #expect(ClipboardSnapshot.decide(items: [
        ["public.utf8-plain-text": 12, "org.nspasteboard.ConcealedType": 0],
    ]) == .take)
}

@Test func exactlyTheLimitAcrossItemsIsTaken() {
    #expect(ClipboardSnapshot.decide(items: [
        ["public.png": 6_000_000], ["public.png": 4_000_000],
    ]) == .take)
}

// MARK: - Skipped

@Test func aFileURLIsSkippedEvenWithText() {
    #expect(ClipboardSnapshot.decide(items: [
        ["public.file-url": 40, "public.utf8-plain-text": 30],
    ]) == .skip(.files))
}

@Test func aPDFIsSkippedAsAFile() {
    #expect(ClipboardSnapshot.decide(items: [["com.adobe.pdf": 5000]]) == .skip(.files))
}

@Test func overTheLimitIsSkipped() {
    #expect(ClipboardSnapshot.decide(items: [["public.png": 10_000_001]]) == .skip(.tooLarge))
}

@Test func filesWinOverSize() {
    #expect(ClipboardSnapshot.decide(items: [["public.file-url": 20_000_000]]) == .skip(.files))
}
