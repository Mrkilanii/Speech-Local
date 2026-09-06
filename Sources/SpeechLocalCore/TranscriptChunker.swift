import Foundation

/// Cuts a transcript into windows a model can actually read.
///
/// An hour of speech is around nine thousand words. Nothing in this app has
/// ever handed the on-device model more than seventy, and its context window is
/// not published — `exceededContextWindowSize` exists as an error for a reason.
/// So a meeting is summarised in windows and the windows are merged.
///
/// Cuts land on sentence boundaries. Splitting mid-sentence costs the model the
/// end of a thought and hands the next window a fragment to open on, and the
/// merge step is where quality is already thinnest.
enum TranscriptChunker {
    /// Words per window.
    ///
    /// Every window is a model call, and a call is the expensive unit: a
    /// 99-minute recording at 1,200 words made 17 of them and took twenty-five
    /// minutes. At 1,800 the same recording is 11 windows.
    ///
    /// The ceiling is the model's 4,096-token context, prompt and answer
    /// together. 1,800 words is ~2,400 tokens, leaving ~1,700 for the
    /// instructions and the bullets — and an overflow is recoverable anyway,
    /// since a refused window is halved and retried.
    static let targetWords = 1_800

    /// A sentence longer than this is not a sentence; it is a transcript with
    /// no punctuation, which happens when the recognizer never hears a pause.
    /// Cut it anyway rather than hand over the whole meeting.
    static let hardLimit = 2_600

    static func chunks(of transcript: String, targetWords: Int = targetWords) -> [String] {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var chunks: [String] = []
        var current: [String] = []
        var count = 0

        for sentence in sentences(of: text) {
            let words = sentence.split(whereSeparator: \.isWhitespace).count
            // Starting a window with a sentence that alone exceeds the target
            // is fine; adding one that pushes past it is not.
            if count > 0, count + words > targetWords {
                chunks.append(current.joined(separator: " "))
                current = []
                count = 0
            }
            current.append(sentence)
            count += words

            if count >= hardLimit {
                chunks.append(current.joined(separator: " "))
                current = []
                count = 0
            }
        }
        if !current.isEmpty { chunks.append(current.joined(separator: " ")) }
        return chunks
    }

    /// Splits on sentence terminators, keeping the punctuation attached.
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
            current = ""
        }
        let trailing = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trailing.isEmpty { out.append(trailing) }
        return out
    }
}
