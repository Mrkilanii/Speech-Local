import Testing
import Foundation
@testable import SpeechLocalCore

private func seg(_ start: Double, _ end: Double, _ text: String) -> TimedSegment {
    TimedSegment(start: start, end: end, text: text)
}

// MARK: - Interleaving

@Test func turnsAlternateInTheOrderTheyWereSaid() {
    let text = SpeakerTurns.render(
        you: [seg(0, 2, "Can you hear me?"), seg(5, 6, "Great.")],
        them: [seg(2.5, 4, "Yes, loud and clear.")])
    #expect(text == "You: Can you hear me?\n\nThem: Yes, loud and clear.\n\nYou: Great.")
}

@Test func consecutiveSegmentsFromOneSideAreOneTurn() {
    let text = SpeakerTurns.render(
        you: [seg(0, 2, "First point."), seg(2.5, 4, "Second point.")],
        them: [seg(5, 6, "Agreed.")])
    #expect(text == "You: First point. Second point.\n\nThem: Agreed.")
}

@Test func aRunIsMergedEvenWhenItsSegmentsArriveOutOfOrder() {
    let text = SpeakerTurns.render(
        you: [seg(9, 10, "Bye."), seg(0, 1, "Hello."), seg(1, 2, "One thing.")],
        them: [seg(5, 6, "Go on.")])
    #expect(text == "You: Hello. One thing.\n\nThem: Go on.\n\nYou: Bye.")
}

@Test func anOverlappingSegmentStaysWholeAndIsPlacedByItsStart() {
    // Them talks from 0 to 30; You cuts in at 10. The interruption is not
    // spliced into the middle of their sentence — the recognizer never said
    // which word was at second 10.
    let text = SpeakerTurns.render(
        you: [seg(10, 12, "Sorry, which quarter?")],
        them: [seg(0, 30, "The numbers for the quarter were down on last year."),
               seg(31, 33, "The third.")])
    #expect(text == """
        Them: The numbers for the quarter were down on last year.

        You: Sorry, which quarter?

        Them: The third.
        """)
}

@Test func aSegmentStartingInsideAnotherStillComesAfterIt() {
    // Order by start, even when the later-starting segment ends first.
    let turns = SpeakerTurns.interleave(
        you: [seg(1, 3, "Short.")],
        them: [seg(0, 20, "A long monologue.")])
    #expect(turns == [
        SpeakerTurn(speaker: .them, start: 0, text: "A long monologue."),
        SpeakerTurn(speaker: .you, start: 1, text: "Short."),
    ])
}

@Test func equalStartsPutYouFirst() {
    let text = SpeakerTurns.render(
        you: [seg(3, 4, "Hi.")], them: [seg(3, 4, "Hello.")])
    #expect(text == "You: Hi.\n\nThem: Hello.")
}

@Test func equalStartsWithinOneSideKeepTheirOrder() {
    let text = SpeakerTurns.render(
        you: [seg(0, 0, "a"), seg(0, 0, "b"), seg(0, 0, "c")],
        them: [seg(1, 2, "d")])
    #expect(text == "You: a b c\n\nThem: d")
}

@Test func blankSegmentsNeitherShowNorBreakARun() {
    // An empty result from the other side between two of yours must not
    // split your turn into two with nothing between them.
    let text = SpeakerTurns.render(
        you: [seg(0, 1, "One."), seg(2, 3, "Two.")],
        them: [seg(1.5, 1.8, "   "), seg(4, 5, "Three.")])
    #expect(text == "You: One. Two.\n\nThem: Three.")
}

@Test func segmentTextIsTrimmed() {
    let text = SpeakerTurns.render(
        you: [seg(0, 1, "  padded.\n")], them: [seg(2, 3, "\tagain. ")])
    #expect(text == "You: padded.\n\nThem: again.")
}

@Test func turnsCarryTheStartOfTheirFirstSegment() {
    let turns = SpeakerTurns.interleave(
        you: [seg(4, 5, "b"), seg(2, 3, "a")], them: [seg(7, 8, "c")])
    #expect(turns.map(\.start) == [2, 7])
    #expect(turns.map(\.text) == ["a b", "c"])
}

// MARK: - Degrading to one side

@Test func onlyTheMicrophoneIsUnlabelled() {
    // An in-person meeting: nothing playing, so the tap delivers nothing and
    // the microphone hears the whole room. "You:" on all of it would be false.
    let text = SpeakerTurns.render(
        you: [seg(0, 1, "Morning."), seg(2, 3, "Let's start.")], them: [])
    #expect(text == "Morning. Let's start.")
}

@Test func onlyTheSystemAudioIsUnlabelled() {
    // A course at 2x: the microphone is not recorded at all.
    let text = SpeakerTurns.render(
        you: [], them: [seg(5, 6, "Welcome back."), seg(0, 1, "Hi.")])
    #expect(text == "Hi. Welcome back.")
}

@Test func aSideWithOnlyBlankSegmentsCountsAsSilent() {
    let text = SpeakerTurns.render(
        you: [seg(0, 1, "Hello?")], them: [seg(0.5, 1, " "), seg(2, 3, "")])
    #expect(text == "Hello?")
}

@Test func nothingSaidIsEmpty() {
    #expect(SpeakerTurns.render(you: [], them: []) == "")
    #expect(SpeakerTurns.interleave(you: [], them: []).isEmpty)
}

// MARK: - Recognising a labelled transcript

@Test func aLabelledTranscriptIsRecognised() {
    #expect(SpeakerTurns.isLabelled("You: hi\n\nThem: hello"))
    #expect(SpeakerTurns.isLabelled("\n  Them: first\n\nYou: second"))
}

@Test func anUnlabelledTranscriptIsNot() {
    #expect(!SpeakerTurns.isLabelled(""))
    #expect(!SpeakerTurns.isLabelled("Youth is wasted on the young."))
    #expect(!SpeakerTurns.isLabelled("Them apples."))
    #expect(!SpeakerTurns.isLabelled("you: lower case is somebody talking"))
    #expect(!SpeakerTurns.isLabelled("We agreed. You: mid-sentence is not a label"))
}

// MARK: - Putting a recognizer on the meeting's clock

@Test func aContinuousSourceKeepsItsOwnClock() {
    var timeline = SourceTimeline()
    timeline.admit(16_000, endingAt: 1)
    timeline.admit(16_000, endingAt: 2)
    timeline.admit(16_000, endingAt: 3)
    #expect(timeline.meetingTime(0) == 0)
    #expect(timeline.meetingTime(2.5) == 2.5)
    #expect(timeline.gaps == 0)
    #expect(timeline.fed == 48_000)
}

@Test func aSourceThatStartsLateIsPlacedWhereItStarted() {
    // Nothing played for five minutes; the tap's recognizer hears its first
    // second at 300 s and calls it zero.
    var timeline = SourceTimeline()
    timeline.admit(16_000, endingAt: 300)
    #expect(timeline.meetingTime(0) == 299)
    #expect(timeline.meetingTime(0.5) == 299.5)
    #expect(timeline.gaps == 0)
}

@Test func aSilentStretchIsSkippedNotCompressed() {
    // A video paused for ten seconds: the tap delivers nothing, so the
    // recognizer's clock stops while the meeting's does not.
    var timeline = SourceTimeline()
    timeline.admit(16_000, endingAt: 1)
    timeline.admit(16_000, endingAt: 12)
    #expect(timeline.meetingTime(0.5) == 0.5)
    #expect(timeline.meetingTime(1.5) == 11.5)
    #expect(timeline.gaps == 1)
}

@Test func drainJitterIsNotAGap() {
    // Reads vary by a capture callback's worth either side of a second.
    var timeline = SourceTimeline()
    let reads = [17_024, 14_976, 16_000, 17_365, 14_635, 16_000]
    for (index, count) in reads.enumerated() {
        timeline.admit(count, endingAt: Double(index + 1))
    }
    #expect(timeline.gaps == 0)
    #expect(timeline.meetingTime(6) == 6)
}

@Test func nothingReadChangesNothing() {
    var timeline = SourceTimeline()
    timeline.admit(0, endingAt: 50)
    #expect(timeline.fed == 0)
    timeline.admit(16_000, endingAt: 60)
    #expect(timeline.meetingTime(0) == 59, "an empty read must not anchor the clock")
}

@Test func placingRetimesStartAndEnd() {
    var timeline = SourceTimeline()
    timeline.admit(32_000, endingAt: 12)
    #expect(timeline.place([seg(0.5, 1.5, "x")]) == [seg(10.5, 11.5, "x")])
}

@Test func twoClocksInterleaveOnTheMeetingsTime() {
    // The microphone runs from the start. The call's audio begins at 4 s,
    // pauses, and comes back at 20 s. On their own clocks both recognizers
    // start at zero; on the meeting's they land between the user's turns.
    var mic = SourceTimeline()
    for second in 1...30 { mic.admit(16_000, endingAt: Double(second)) }
    var system = SourceTimeline()
    system.admit(16_000, endingAt: 5)
    system.admit(16_000, endingAt: 6)
    system.admit(16_000, endingAt: 21)

    let text = SpeakerTurns.render(
        you: mic.place([seg(1, 3, "Are you there?"), seg(10, 12, "Hello?"),
                        seg(25, 26, "Ah, good.")]),
        them: system.place([seg(0.2, 1.8, "One moment."), seg(2.1, 2.9, "Back.")]))
    #expect(text == """
        You: Are you there?

        Them: One moment.

        You: Hello?

        Them: Back.

        You: Ah, good.
        """)
}
