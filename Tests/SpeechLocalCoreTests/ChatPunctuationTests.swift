import Testing
@testable import SpeechLocalCore

private let messages = "com.apple.MobileSMS"
private let whatsApp = "net.whatsapp.WhatsApp"
private let claude = "com.anthropic.claudefordesktop"

// MARK: - The acceptance table (Messages unless stated)

@Test func dropsTheStopOnAShortMessage() {
    #expect(ChatPunctuation.apply("See you soon.", bundleID: messages) == "See you soon")
}

@Test func dropsTheStopWhenThereAreTwoSentences() {
    #expect(ChatPunctuation.apply("Sounds good. See you at 3.", bundleID: messages)
        == "Sounds good. See you at 3")
}

@Test func aDecimalPointIsNotASentenceEnd() {
    #expect(ChatPunctuation.apply("It's 3.5.", bundleID: messages) == "It's 3.5")
}

@Test func keepsTheStopWhenThereAreThreeSentenceEnds() {
    #expect(ChatPunctuation.apply("Dr. Smith. See you.", bundleID: messages)
        == "Dr. Smith. See you.")
}

@Test func keepsAQuestionMark() {
    #expect(ChatPunctuation.apply("Really?", bundleID: messages) == "Really?")
}

@Test func keepsAnEllipsis() {
    #expect(ChatPunctuation.apply("Wait...", bundleID: messages) == "Wait...")
}

@Test func dropsTheStopInWhatsApp() {
    #expect(ChatPunctuation.apply("See you soon.", bundleID: whatsApp) == "See you soon")
}

@Test func keepsTheStopInAnAppThatIsNotForMessaging() {
    #expect(ChatPunctuation.apply("See you soon.", bundleID: claude) == "See you soon.")
}

@Test func keepsTheStopWithNoApp() {
    #expect(ChatPunctuation.apply("See you soon.", bundleID: nil) == "See you soon.")
}

// MARK: - The app list

@Test func matchesEveryMessagingAppIgnoringCase() {
    for id in ["com.apple.MobileSMS", "COM.APPLE.MOBILESMS", "net.whatsapp.WhatsApp",
               "com.hnc.Discord", "com.microsoft.teams"] {
        #expect(ChatPunctuation.apply("See you soon.", bundleID: id) == "See you soon", "\(id)")
    }
}
