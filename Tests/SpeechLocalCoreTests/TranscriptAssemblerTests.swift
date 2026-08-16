import Testing
import CoreMedia
@testable import SpeechLocalCore

private func range(_ start: Double, _ end: Double) -> CMTimeRange {
    CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                end: CMTime(seconds: end, preferredTimescale: 600))
}

@Test func keepsSuccessiveSegments() {
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 2), text: "First sentence.", isFinal: true)
    assembler.add(range: range(2, 4), text: "Second sentence.", isFinal: true)
    #expect(assembler.finalized == "First sentence. Second sentence.")
}

@Test func volatileTextNeverReachesTheTranscript() {
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 1), text: "2052", isFinal: false)
    #expect(assembler.finalized.isEmpty)
    #expect(assembler.live == "2052")
}

@Test func finalResultSupersedesItsVolatileForm() {
    // The reported bug: a dictated "2052" came back as "2052. 2052." because
    // the finalized range did not start where the volatile one did.
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0.0, 0.9), text: "2052", isFinal: false)
    assembler.add(range: range(0.1, 1.0), text: "2052.", isFinal: true)
    #expect(assembler.finalized == "2052.")
    #expect(assembler.live == "2052.")
}

@Test func aRefinedSegmentReplacesTheOnesItCovers() {
    // The analyzer re-segments as it gains context: one final result can span
    // audio already reported as two.
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 1), text: "Call", isFinal: true)
    assembler.add(range: range(1, 2), text: "021.", isFinal: true)
    assembler.add(range: range(0, 2), text: "Call 021.", isFinal: true)
    #expect(assembler.finalized == "Call 021.")
}

@Test func touchingSegmentsAreNotOverlapping() {
    // [0,2) and [2,4) share an instant, not audio — both must survive.
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 2), text: "One.", isFinal: true)
    assembler.add(range: range(2, 4), text: "Two.", isFinal: true)
    #expect(assembler.finalized == "One. Two.")
}

@Test func aLaterVolatileDoesNotResurrectAfterFinalizing() {
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 1), text: "Done.", isFinal: true)
    #expect(assembler.live == "Done.")
}

@Test func emptyResultsAreIgnored() {
    var assembler = TranscriptAssembler()
    assembler.add(range: range(0, 1), text: "   ", isFinal: true)
    assembler.add(range: range(1, 2), text: "Real.", isFinal: true)
    #expect(assembler.finalized == "Real.")
}
