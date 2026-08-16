import Foundation

/// The two dictation modes, bound to two separate hotkeys.
public enum CleanupMode: String, Sendable, CaseIterable {
    /// Punctuation, capitalization, disfluency removal. Content is preserved
    /// exactly. Streams to the target app sentence by sentence.
    case lightTouch

    /// Full rewrite into structured prose. Reorders material, so it is buffered
    /// whole and inserted once — streaming would be incoherent.
    case fullRewrite

    /// Whether output may be streamed into the target app as it generates.
    ///
    /// Only light-touch qualifies: its output order tracks input order, so a
    /// committed prefix stays correct. Full rewrite may move material that was
    /// already inserted, which cannot be undone in someone else's document.
    public var supportsStreaming: Bool {
        switch self {
        case .lightTouch: return true
        case .fullRewrite: return false
        }
    }

    /// Wall-clock budget before the pipeline abandons generation and falls back
    /// to the raw transcript.
    ///
    /// Measured on a base M1 (idle): light-touch runs ~705 ms to first token,
    /// ~947 ms total. Under machine load the *same* configuration measured
    /// 4–15 s, so these ceilings are deliberately generous — they exist to catch
    /// a hang, not to enforce the latency target.
    public var timeout: Duration {
        switch self {
        case .lightTouch: return .seconds(8)
        case .fullRewrite: return .seconds(45)
        }
    }
}
