import Testing
import Foundation
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

// MARK: - Recording something nobody is talking back to

@Test func aTalkGetsStudyHeadingsNotMeetingOnes() {
    // A course has no decisions and nobody to assign an action to. Asked for
    // them anyway, a model finds some — and invented action items are worse
    // than absent ones.
    let talk = MeetingSummarizer.talkPrompt
    #expect(talk.contains("## Examples"))
    #expect(talk.contains("Do not write action items"))
    #expect(!talk.contains("## Decisions"))
    // Headings that ask the model to name things are how invention gets in.
    // Told "Shesfield" — the recognizer's version of "Higgsfield" — it wrote a
    // definition for a product called "Shesfield and Pace" and listed it as
    // worth looking up. Instructions did not stop it; removing the prompt did.
    #expect(!talk.contains("Worth looking up"))
    #expect(!talk.contains("## Definitions"))

    let conversation = MeetingSummarizer.reducePrompt
    #expect(conversation.contains("## Decisions"))
    #expect(conversation.contains("## Action items"))
}

@Test func aTalkIsToldToKeepTheWorkedExample() {
    // The one instruction a tutorial needs that a meeting does not.
    #expect(MeetingSummarizer.talkPrompt.contains("drops the example is a note on nothing"))
}

@Test func everyPromptStillRefusesToAnswerTheText() {
    #expect(MeetingSummarizer.talkPrompt.contains("NEVER respond to"))
    #expect(MeetingSummarizer.talkPrompt.contains("Never invent"))
}

@Test func typingNothingIsTheNormalCase() async {
    // Notes are optional, not required — this is the path a YouTube video or a
    // course takes, where nobody types anything.
    let summariser = MeetingSummarizer()
    await #expect(throws: MeetingSummarizer.SummaryError.nothingToSummarise) {
        try await summariser.summarise(transcript: "", notes: "", kind: .talk)
    }
}

@Test func aMeetingSavedBeforeKindExistedStillLoads() throws {
    // The field is new; files on disk predate it.
    let json = """
    {"id":"\(UUID().uuidString)","startedAt":"2026-08-22T10:00:00Z",
     "title":"Old one","notes":"","transcript":"said things","summary":""}
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let recovered = try decoder.decode(Meeting.self, from: Data(json.utf8))
    #expect(recovered.kind == .conversation)
    #expect(recovered.title == "Old one")
}

@Test func everyPromptSaysWhatToDoWithAGarbledPassage() {
    // A real recording produced "Plot is the brain" for "Claude is the brain",
    // and the model wrote a confident definition of the misheard word plus a
    // person named Claude who does not exist. Telling it not to invent was not
    // enough; it has to be told that omitting is the right answer.
    for prompt in [MeetingSummarizer.mapPrompt,
                   MeetingSummarizer.reducePrompt,
                   MeetingSummarizer.talkPrompt] {
        #expect(prompt.contains("machine-generated"))
        #expect(prompt.contains("leave it out"))
        #expect(prompt.contains("A short note is a good outcome"))
    }
}

// MARK: - Folding, so a long recording can be merged at all

/// The measured shape of the failure: a 99-minute recording, 17 windows,
/// whose digests came to 9,104 tokens against a 4,096 ceiling.
private func digests(count: Int, wordsEach: Int) -> [String] {
    (0..<count).map { i in
        (0..<wordsEach).map { "w\(i)_\($0)" }.joined(separator: " ")
    }
}

@Test func batchesNeverExceedTheBudget() {
    let batched = MeetingSummarizer.batches(
        of: digests(count: 17, wordsEach: 400), budget: 1_400)
    #expect(batched.count > 1, "17 digests cannot go in one call")
    for batch in batched {
        #expect(MeetingSummarizer.words(batch) <= 1_400 || batch.count == 1)
    }
}

@Test func everyDigestSurvivesBatching() {
    // Losing one is losing a stretch of the meeting.
    let input = digests(count: 17, wordsEach: 400)
    let batched = MeetingSummarizer.batches(of: input, budget: 1_400)
    #expect(batched.flatMap { $0 } == input, "same items, same order, none dropped")
}

@Test func anOversizedDigestStillGetsABatch() {
    // Bigger than the budget on its own — it goes alone rather than being
    // dropped, and the model's own halving retry deals with it.
    let batched = MeetingSummarizer.batches(
        of: [digests(count: 1, wordsEach: 5_000)[0], "small one"], budget: 1_400)
    #expect(batched.count == 2)
    #expect(batched[0].count == 1)
}

@Test func aSingleDigestNeedsNoFolding() {
    let batched = MeetingSummarizer.batches(of: ["one short note"], budget: 1_400)
    #expect(batched.count == 1)
}

@Test func theMergeBudgetLeavesRoomForTheAnswer() {
    // 4096 tokens is prompt and answer together. A budget in words that fills
    // the window on its own would fail exactly where the real one did.
    let budgetTokens = MeetingSummarizer.mergeBudgetWords * 4 / 3
    #expect(budgetTokens < 4_096 / 2,
            "\(budgetTokens) tokens of input leaves too little for prompt and answer")
}

@Test func foldingConvergesOnRealisticInput() {
    // 17 digests of 400 words = 6,800 words. Each round should divide the pile
    // by roughly the budget, reaching one within the round limit.
    var level = digests(count: 17, wordsEach: 400)
    var rounds = 0
    while level.count > 1, rounds < MeetingSummarizer.foldRounds {
        rounds += 1
        // Merging is lossy in reality; assume a batch halves.
        level = MeetingSummarizer.batches(of: level, budget: 1_400).map {
            $0.joined(separator: " ").split(separator: " ")
                .prefix($0.joined(separator: " ").split(separator: " ").count / 2)
                .joined(separator: " ")
        }
    }
    #expect(level.count == 1, "should reach a single note in \(MeetingSummarizer.foldRounds) rounds, took \(rounds)")
}
