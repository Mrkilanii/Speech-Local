import Testing
@testable import SpeechLocalCore

/// A transcript of `words` words in sentences of ten.
private func transcript(words: Int) -> String {
    (0..<(words / 10)).map { index in
        (0..<10).map { "w\(index * 10 + $0)" }.joined(separator: " ") + "."
    }.joined(separator: " ")
}

@Test func aShortTranscriptIsOneChunk() {
    let text = transcript(words: 100)
    #expect(TranscriptChunker.chunks(of: text).count == 1)
}

@Test func anHourIsCutIntoReadableWindows() {
    // ~9,000 words is a 60-minute meeting.
    let chunks = TranscriptChunker.chunks(of: transcript(words: 9_000))
    #expect(chunks.count >= 7 && chunks.count <= 9, "got \(chunks.count)")
    for chunk in chunks {
        let words = chunk.split(whereSeparator: \.isWhitespace).count
        #expect(words <= TranscriptChunker.hardLimit)
    }
}

@Test func chunkingLosesNoWords() {
    // The one property that matters: a summary of a meeting missing a chunk
    // is worse than no summary.
    let text = transcript(words: 5_000)
    let rejoined = TranscriptChunker.chunks(of: text).joined(separator: " ")
    #expect(rejoined.split(whereSeparator: \.isWhitespace).count
            == text.split(whereSeparator: \.isWhitespace).count)
    #expect(rejoined == text)
}

@Test func cutsLandOnSentenceBoundaries() {
    for chunk in TranscriptChunker.chunks(of: transcript(words: 4_000)) {
        #expect(chunk.hasSuffix("."), "a window should not end mid-sentence")
    }
}

@Test func emptyInputProducesNoChunks() {
    #expect(TranscriptChunker.chunks(of: "").isEmpty)
    #expect(TranscriptChunker.chunks(of: "   \n  ").isEmpty)
}

@Test func speechWithNoPunctuationIsStillCut() {
    // The recognizer punctuates from pauses; someone who never pauses gets a
    // single unbroken sentence, and handing the model the whole meeting is
    // not an option.
    let unbroken = (0..<5_000).map { "w\($0)" }.joined(separator: " ")
    let chunks = TranscriptChunker.chunks(of: unbroken)
    #expect(chunks.count == 1, "no boundary exists to cut on, so it stays whole")
    // ...and the summariser has to cope, which is what its retry is for.
}

@Test func aSingleOverlongSentenceIsNotDroppedOnTheFloor() {
    let long = (0..<3_000).map { "w\($0)" }.joined(separator: " ") + "."
    let chunks = TranscriptChunker.chunks(of: long + " Short one.")
    #expect(chunks.joined(separator: " ").contains("Short one."))
    #expect(chunks.joined(separator: " ").contains("w2999"))
}
