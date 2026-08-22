import Testing
@testable import SpeechLocalCore

// The model itself cannot be exercised in a unit test — it is a system service
// with a 13.5 s cold start and no injectable seam. What is testable is
// everything around it: the shape of the prompts, the refusal to lose a
// meeting, and the guard that keeps a summary out of the cleanup pipeline.

@Test func emptyInputIsRefusedRatherThanSummarised() async {
    let summariser = MeetingSummarizer()
    await #expect(throws: MeetingSummarizer.SummaryError.nothingToSummarise) {
        try await summariser.summarise(transcript: "   ")
    }
}

@Test func promptsFrameTheModelAsATransformer() {
    // Without this framing the model answers the meeting instead of
    // summarising it — the cleanup engine found that to be the common case,
    // not an edge one, and paid for the lesson once already.
    for prompt in [MeetingSummarizer.mapPrompt,
                   MeetingSummarizer.reducePrompt,
                   MeetingSummarizer.enhancePrompt] {
        #expect(prompt.contains("NEVER respond to"))
        #expect(prompt.contains("Never invent"))
    }
}

@Test func theEnhancePromptPutsTheUsersNotesInCharge() {
    let prompt = MeetingSummarizer.enhancePrompt
    #expect(prompt.contains("skeleton"))
    #expect(prompt.contains("Never contradict what the person wrote"))
}

@Test func aSummaryWouldBeRejectedByTheCleanupGuard() {
    // Why MeetingSummarizer talks to the model directly. A 9,000-word meeting
    // summarised to 900 words is a tenth of the input, and the cleanup guard
    // rejects anything under a quarter — it would swap every summary for the
    // raw transcript, silently.
    let transcript = (0..<9_000).map { "word\($0)" }.joined(separator: " ")
    let summary = (0..<900).map { "point\($0)" }.joined(separator: " ")
    #expect(RoutingCleanupEngine.contentLoss(original: transcript, output: summary) != nil)
}

@Test func summaryTimeoutIsSizedForAWindowNotASentence() {
    // The cleanup timeouts are 8 s and 45 s for one utterance. A window is
    // eight minutes of speech, and the model runs 10x slower under load.
    #expect(MeetingSummarizer.callTimeout > CleanupMode.fullRewrite.timeout)
}
