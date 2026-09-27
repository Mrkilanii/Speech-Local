import Testing
@testable import SpeechLocalCore

@Test(arguments: [
    ("Let's meet at 2, like, actually 3.", "Let's meet at 3."),
    ("Tell him it's late, scratch that, tell him it's ready.", "tell him it's ready."),
    ("So, like, we ship Monday, no actually Tuesday.", "So we ship Tuesday."),
])
func backtrackComposesTheThreeStages(spoken: String, expected: String) {
    #expect(Backtrack.apply(spoken) == expected)
}

@Test func ordinarySpeechPassesThrough() {
    for entry in LightTouchInvariants.corpus {
        #expect(Backtrack.apply(entry.input) == entry.input, "\(entry.input)")
    }
}

@Test func omarsCorrectionThroughTheWholePipeline() {
    // doctor.log 27 Sep: typed "At 2 actually 3." before this fix.
    #expect(RulesCleanup().apply(to: Backtrack.apply("At two, actually three.")) == "At 3.")
}
