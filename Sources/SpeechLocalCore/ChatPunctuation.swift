import Foundation

/// Drops the full stop that closes a short message sent into a chat app.
///
/// In a chat a trailing period reads as curt — "See you soon." lands colder
/// than "See you soon" — so people leave it off, and a dictated message with
/// one looks typed by somebody else.
///
/// Only the last character is ever touched, and only when all of these hold:
/// the frontmost app is a messaging app; the text ends in `.` but not `..`,
/// so an ellipsis survives; and it holds at most two sentence ends. A longer
/// text is closer to a written paragraph than a chat line, and keeps its stop.
public enum ChatPunctuation {
    /// Messaging apps, stored lowercased; the frontmost app's ID is lowercased
    /// before it is looked up, so the comparison ignores case.
    ///
    /// Every ID was read from `CFBundleIdentifier` in the app's own
    /// `Contents/Info.plist` on 27 September 2026. Slack, Telegram and Signal
    /// were not installed then, so they are absent rather than guessed.
    static let messagingApps: Set<String> = [
        // Messages — /System/Applications/Messages.app
        "com.apple.mobilesms",
        // WhatsApp — /Applications/WhatsApp.app
        "net.whatsapp.whatsapp",
        // Discord — /Applications/Discord.app
        "com.hnc.discord",
        // Microsoft Teams classic — /Applications/Microsoft Teams classic.app
        "com.microsoft.teams",
    ]

    /// The most sentence ends a text may hold and still read as a chat line.
    static let maxSentenceEnds = 2

    public static func apply(_ text: String, bundleID: String?) -> String {
        guard let bundleID, messagingApps.contains(bundleID.lowercased()) else { return text }
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return text }
        guard sentenceEnds(in: text) <= maxSentenceEnds else { return text }
        return String(text.dropLast())
    }

    /// Counts `.`, `!` and `?` that sit before whitespace or the end of the
    /// text. A stop inside a token — "3.5", "e.g" — is not a sentence end.
    private static func sentenceEnds(in text: String) -> Int {
        let characters = Array(text)
        return characters.indices.filter { i in
            guard ".!?".contains(characters[i]) else { return false }
            let next = i + 1
            return next == characters.count || characters[next].isWhitespace
        }.count
    }
}
