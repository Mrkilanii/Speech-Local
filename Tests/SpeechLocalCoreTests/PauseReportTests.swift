import Testing
@testable import SpeechLocalCore

@Test func reportsTheGapAtEachBoundary() {
    let segments = [
        TimedSegment(start: 0.5, end: 2.0, text: "So I was planning on doing like two, actually three."),
        TimedSegment(start: 2.42, end: 2.9, text: "Logs."),
    ]
    #expect(PauseReport.describe(segments) == "three.|420 Logs.")
    #expect(PauseReport.describe(Array(segments.prefix(1))) == "")
}
