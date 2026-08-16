import Foundation

/// Routes each mode to the engine that measurement showed suits it.
///
/// * **Light-touch → rules.** Sub-millisecond, deterministic, structurally
///   incapable of dropping content. The common case, so it must be instant.
/// * **Full rewrite → LLM.** Rewording is the whole point, and the user
///   explicitly asked for it, so a multi-second wait is acceptable.
public struct RoutingCleanupEngine: CleanupEngine {
    private let rules = RulesCleanup()
    private let llm: any CleanupEngine

    public init(llm: any CleanupEngine) { self.llm = llm }

    /// Light-touch always works, so the app is never fully unavailable. Only
    /// full rewrite depends on the model.
    public func availability() async -> CleanupAvailability {
        await llm.availability()
    }

    public func warmUp() async { await llm.warmUp() }

    public func stream(
        transcript: String,
        mode: CleanupMode,
        vocabulary: Vocabulary
    ) -> AsyncThrowingStream<String, Error> {
        switch mode {
        case .lightTouch:
            let matcher = VocabularyMatcher()
            let substituted = matcher.apply(vocabulary, to: transcript)
            let cleaned = rules.apply(to: substituted)
            return AsyncThrowingStream { continuation in
                continuation.yield(cleaned)
                continuation.finish()
            }

        case .fullRewrite:
            return guarded(
                llm.stream(transcript: transcript, mode: mode, vocabulary: vocabulary),
                original: transcript
            )
        }
    }

    /// Rejects output that lost the user's content.
    ///
    /// Measured failure: on 2 of 10 corpus items the model returned truncated or
    /// empty text **and raised no error** — `refusals: 0/10`. Silent deletion is
    /// the worst outcome available, so the stream fails instead, letting the
    /// pipeline fall back to the raw transcript.
    private func guarded(
        _ upstream: AsyncThrowingStream<String, Error>,
        original: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var last = ""
                do {
                    for try await chunk in upstream {
                        last = chunk
                        continuation.yield(chunk)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                if let problem = Self.contentLoss(original: original, output: last) {
                    continuation.finish(throwing: CleanupUnavailable.refused(problem))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Describes the loss if the output is unusable, else nil.
    ///
    /// A rewrite legitimately shortens text, so the bar is deliberately low —
    /// this catches catastrophic loss, not stylistic compression.
    static func contentLoss(original: String, output: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty output" }

        let inWords = original.split(whereSeparator: \.isWhitespace).count
        let outWords = trimmed.split(whereSeparator: \.isWhitespace).count
        guard inWords >= 8 else { return nil }   // too short to judge

        // 0.25, not 0.4: a full rewrite legitimately compresses rambling
        // speech hard — 18 rambling words to 7 clean ones is a good result, not
        // a failure. This threshold catches catastrophe, not concision.
        if Double(outWords) < Double(inWords) * 0.25 {
            return "output lost \(inWords - outWords) of \(inWords) words"
        }
        // Truncation signature: ends mid-clause on a conjunction or article.
        let danglers: Set<String> = ["and", "or", "but", "the", "a", "an", "to", "of", "for", "with"]
        if let last = trimmed.split(whereSeparator: \.isWhitespace).last,
           danglers.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)) {
            return "output ends mid-clause on '\(last)'"
        }
        return nil
    }
}
