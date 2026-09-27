import Foundation

/// Deletes what the speaker retracted with "scratch that".
///
///     "Tell him it's late, scratch that, tell him it's ready."
///         ->  "tell him it's ready."
///
/// Decision 01 gave up on spoken self-correction because resolving "what did
/// they mean instead" needs meaning. "Scratch that" does not: it is an explicit
/// command with an explicit scope, and it is Wispr Flow's documented trigger.
/// So it can be a rule without breaking the light-touch promise — the speaker
/// marked the deletion, the rule only carries it out.
///
/// The scope is **the sentence the trigger is in**, up to and including the
/// trigger. When the trigger opens its own sentence ("Tell him it's late.
/// Scratch that.") there is nothing before it in that sentence, so the scope is
/// the sentence before. A sentence ends at a token whose trailing punctuation
/// contains `.`, `!` or `?` — defined by characters on purpose, so an
/// abbreviation ending a "sentence" early only ever makes the deletion smaller.
///
/// Two guards keep "scratch that" as ordinary words when it is not a command:
///
/// 1. **"that" must end a clause** — carry punctuation or be the last token.
///    "Scratch that surface gently" is an instruction about a surface.
/// 2. **A negating or modal word before it** ("don't", "will", "to", ...)
///    makes "scratch" the verb. The word is compared by its core, lowercased,
///    so "don't," still counts. This applies even across a full stop, which
///    can leave a real command unexecuted — that failure leaves the words in
///    place, where the opposite one would delete them.
///
/// Repeated triggers ("A. B. Scratch that. Scratch that.") each retract one
/// more sentence, so the text is rescanned from the start until none remain.
/// Capitalisation of what is left is `RulesCleanup`'s job, which runs next.
public enum ScratchThat {
    /// Words that, just before "scratch", make it the verb and not the command.
    static let negators: Set<String> = [
        "don't", "dont", "not", "never", "to", "will", "can", "can't",
        "cannot", "could", "would", "should", "didn't", "won't",
    ]

    public static func apply(_ text: String) -> String {
        var tokens = Token.split(text)
        var changed = false
        while let trigger = firstTrigger(in: tokens) {
            let start = deletionStart(tokens, trigger: trigger)
            tokens.removeSubrange(start...(trigger + 1))
            changed = true
        }
        // With nothing retracted, hand the text back byte for byte: this stage
        // must not normalise whitespace the speaker never asked to change.
        guard changed else { return text }
        return Token.join(tokens).trimmingCharacters(in: .whitespaces)
    }

    /// Index of the first "scratch" that begins a live trigger.
    private static func firstTrigger(in tokens: [String]) -> Int? {
        tokens.indices.first { index in
            let scratch = Token.parts(of: tokens[index])
            guard scratch.leading.isEmpty, scratch.trailing.isEmpty,
                  scratch.core.lowercased() == "scratch",
                  let next = tokens[safe: index + 1]
            else { return false }

            let that = Token.parts(of: next)
            guard that.leading.isEmpty, that.core.lowercased() == "that",
                  !that.trailing.isEmpty || index + 1 == tokens.count - 1
            else { return false }

            if let previous = tokens[safe: index - 1],
               negators.contains(Token.word(previous)) { return false }
            return true
        }
    }

    private static func deletionStart(_ tokens: [String], trigger: Int) -> Int {
        let own = sentenceStart(tokens, containing: trigger)
        guard own == trigger, trigger > 0 else { return own }
        return sentenceStart(tokens, containing: trigger - 1)
    }

    /// First index of the sentence that `index` belongs to.
    private static func sentenceStart(_ tokens: [String], containing index: Int) -> Int {
        var start = index
        while start > 0, !endsSentence(tokens[start - 1]) { start -= 1 }
        return start
    }

    private static func endsSentence(_ token: String) -> Bool {
        Token.parts(of: token).trailing.contains { ".!?".contains($0) }
    }
}
