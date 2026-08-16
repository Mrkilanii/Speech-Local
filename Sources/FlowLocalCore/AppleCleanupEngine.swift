import Foundation
import FoundationModels

/// Cleanup backed by Apple's on-device model.
///
/// Configuration here is measured, not guessed — see `clone-run/research.md`
/// Spike 3. Two settings look like details and are not:
///
/// * **A fresh `LanguageModelSession` per dictation.** Reusing one is *slower*
///   (median 701 ms, max 3826 ms, 5/8 within budget) than creating a new one
///   (median 577 ms, max 659 ms, 8/8 within budget), because accumulated history
///   grows prefill every turn. It is also semantically correct: dictations must
///   not see each other. Do not "optimize" this into a shared session.
///
/// * **`sampling: .greedy`.** Determinism is free — greedy measured marginally
///   *faster* than default sampling (705 ms vs 742 ms first-token) with a tighter
///   maximum. Default sampling produces different output for identical input,
///   which for light-touch mode is a correctness bug.
public struct AppleCleanupEngine: CleanupEngine {
    private let matcher = VocabularyMatcher()

    public init() {}

    // MARK: - Availability

    public func availability() async -> CleanupAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(Self.map(reason))
        @unknown default:
            return .unavailable(.other("unrecognized availability case"))
        }
    }

    private static func map(
        _ reason: SystemLanguageModel.Availability.UnavailableReason
    ) -> CleanupUnavailable {
        switch reason {
        case .appleIntelligenceNotEnabled: return .notEnabled
        case .modelNotReady: return .modelNotReady
        case .deviceNotEligible: return .unsupportedDevice
        @unknown default: return .other("\(reason)")
        }
    }

    // MARK: - Warm-up

    /// The first-ever generation measured **13.5 s**, and throughput kept
    /// improving across three consecutive runs. `prewarm()` alone is not enough,
    /// so this also issues a real throwaway generation.
    public func warmUp() async {
        let session = LanguageModelSession(instructions: Self.prompt(for: .lightTouch))
        session.prewarm()
        _ = try? await session.respond(to: "hello", options: Self.options)
    }

    // MARK: - Generation

    private static let options = GenerationOptions(sampling: .greedy)

    public func stream(
        transcript: String,
        mode: CleanupMode,
        vocabulary: Vocabulary
    ) -> AsyncThrowingStream<String, Error> {
        // Vocabulary is applied *before* cleanup so the model sees correct proper
        // nouns and punctuates around them. Applying it afterwards would require
        // matching against text the model may already have altered.
        let input = matcher.apply(vocabulary, to: transcript)
        let instructions = Self.prompt(for: mode)
        let timeout = mode.timeout

        return AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await partial in session.streamResponse(
                        to: input, options: Self.options
                    ) {
                        try Task.checkCancellation()
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: CleanupUnavailable.timedOut)
                } catch {
                    continuation.finish(throwing: Self.classify(error))
                }
            }

            let watchdog = Task {
                try? await Task.sleep(for: timeout)
                if !work.isCancelled { work.cancel() }
            }

            continuation.onTermination = { _ in
                work.cancel()
                watchdog.cancel()
            }
        }
    }

    /// Guardrail refusals are expected occasionally — this is a safety-filtered
    /// model and dictation is arbitrary speech. They must be distinguishable so
    /// the pipeline can fall back to the raw transcript rather than surfacing a
    /// generic failure.
    private static func classify(_ error: Error) -> CleanupUnavailable {
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .guardrailViolation:
                return .refused("\(generation)")
            default:
                return .other("\(generation)")
            }
        }
        return .other("\(error)")
    }

    // MARK: - Prompts

    /// Naming exactly what to preserve is what fixed content loss in testing.
    /// A generic "don't reword" instruction was **not** enough — the model
    /// dropped hedges like "I think" and once inserted a word never spoken.
    static func prompt(for mode: CleanupMode) -> String {
        switch mode {
        case .lightTouch:
            return """
            Add punctuation and capitalization to dictated speech. Remove only \
            filler words (um, uh, er, ah) and immediate word repetitions \
            ("the the" becomes "the"). Keep every other word exactly as spoken, \
            including hedges (I think, maybe, sort of), discourse markers (so, \
            well, you know, actually, okay), and casual forms (gonna, dont, \
            thats). Never add words. Never remove content words. Never rephrase, \
            shorten, or summarize. Do not alter proper nouns. Output only the \
            cleaned text.
            """
        case .fullRewrite:
            return """
            Rewrite dictated speech as clear, well-structured prose. Remove \
            filler and false starts, fix grammar, and organize the material into \
            coherent sentences and paragraphs. Preserve the speaker's meaning, \
            intent, and every substantive point — never invent information and \
            never drop a point the speaker made. Output only the rewritten text.
            """
        }
    }
}
