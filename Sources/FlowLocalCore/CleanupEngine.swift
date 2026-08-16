import Foundation

/// Why a cleanup engine could not run. Every case must degrade to inserting the
/// raw transcript — the pipeline never loses the user's words.
public enum CleanupUnavailable: Error, Sendable, Equatable {
    /// Apple Intelligence is switched off in System Settings.
    case notEnabled
    /// Enabled, but the OS has not finished downloading or preparing the model.
    case modelNotReady
    /// The device does not support the on-device model at all.
    case unsupportedDevice
    /// Generation exceeded the mode's wall-clock budget.
    case timedOut
    /// The model refused the input. Expected occasionally: this is a
    /// safety-filtered model and dictation is arbitrary user speech.
    case refused(String)
    case other(String)
}

/// Rewrites a raw transcript according to a `CleanupMode`.
///
/// Deliberately provider-agnostic. `FoundationModels` types must not appear in
/// this signature — the MLX contingency depends on this boundary holding.
public protocol CleanupEngine: Sendable {
    /// Whether the engine can run right now. Checked at launch *and* before each
    /// session, because availability is a runtime feature flag, not a constant.
    func availability() async -> CleanupAvailability

    /// Warms the engine so the first real dictation is not the cold path.
    ///
    /// Measured: the first-ever generation took 13.5 s, and throughput kept
    /// improving across three consecutive runs. One `prewarm` call is not
    /// enough to reach steady state; implementations should issue at least one
    /// real throwaway generation.
    func warmUp() async

    /// Streams cleaned text.
    ///
    /// Emits *cumulative* content, not deltas — callers diff against what they
    /// have already committed. For `.fullRewrite` the stream is permitted to
    /// emit exactly once, at the end.
    func stream(
        transcript: String,
        mode: CleanupMode,
        vocabulary: Vocabulary
    ) -> AsyncThrowingStream<String, Error>
}

public enum CleanupAvailability: Sendable, Equatable {
    case available
    case unavailable(CleanupUnavailable)
}

/// A cleanup engine that always reports unavailable.
///
/// Used when the OS model is missing so the pipeline still runs end to end and
/// degrades visibly, rather than the app failing to start.
public struct UnavailableCleanupEngine: CleanupEngine {
    public let reason: CleanupUnavailable

    public init(reason: CleanupUnavailable) { self.reason = reason }

    public func availability() async -> CleanupAvailability { .unavailable(reason) }
    public func warmUp() async {}

    public func stream(
        transcript: String,
        mode: CleanupMode,
        vocabulary: Vocabulary
    ) -> AsyncThrowingStream<String, Error> {
        let reason = self.reason
        return AsyncThrowingStream { $0.finish(throwing: reason) }
    }
}
