import Foundation

/// Decides when the clipboard the user had before a dictation may be put back.
///
/// Pasting borrows the clipboard: the transcript goes on, ⌘V is posted, and the
/// old contents are restored afterwards. Restoring on a timer is how the
/// previous clipboard came to be pasted instead of the transcript — a slow
/// target reads the clipboard after it has already been swapped back. So a
/// restore needs evidence that the paste was consumed, never elapsed time alone:
///
/// * **The field shows the text** (`axConfirmed`). Conclusive, when the target
///   exposes its field at all.
/// * **Someone read our clipboard item after ⌘V was posted.** Only counted while
///   reads are attributable. The clipboard server does not say who read, and
///   caches the first answer, so a clipboard manager reading early hides the
///   target's read; when one may be running, reads prove nothing.
///
/// With no evidence after two seconds the transcript stays on the clipboard.
/// Leaving the user's clipboard changed is recoverable; pasting their old
/// clipboard into a document is not.
///
/// One case remains open by design: an unlisted reader that reads after ⌘V but
/// before a target slower than half a second. A read cannot be attributed to a
/// process, so nothing here can tell the two apart.
public enum PasteRestore {
    public enum Decision: Sendable, Equatable {
        /// No verdict yet; ask again at this time.
        case wait(until: TimeInterval)
        case restore
        /// No evidence the paste landed. Restoring now could paste the old
        /// clipboard, so the transcript stays.
        case keepTranscript
        /// The user copied something since the paste. Their copy wins, and the
        /// snapshot is stale.
        case abandon
    }

    /// Reads are waited for this long before the transcript is kept instead.
    static let evidenceWindow: TimeInterval = 2.0
    /// Never restore sooner than this after ⌘V, even with a read in hand — the
    /// read may be a reader other than the target.
    static let minimumDelay: TimeInterval = 0.5
    /// After the last read, allow the target this long to finish with the data.
    static let settleAfterRead: TimeInterval = 0.2

    /// - Parameters:
    ///   - now: the current time, on the same clock as `postedAt` and `reads`.
    ///   - postedAt: when ⌘V was posted.
    ///   - reads: when our lazy clipboard item was read. Reads before
    ///     `postedAt` came from something other than the paste and are ignored.
    ///   - readsAttributable: false when a known reader that ignores the
    ///     transient marker is running, so a read may not be the target's.
    ///   - axConfirmed: the focused field now contains the transcript more
    ///     times than it did before the paste.
    ///   - changeCount: the clipboard's change count now.
    ///   - ourChangeCount: the change count after we wrote the transcript.
    public static func decide(
        now: TimeInterval,
        postedAt: TimeInterval,
        reads: [TimeInterval],
        readsAttributable: Bool,
        axConfirmed: Bool,
        changeCount: Int,
        ourChangeCount: Int
    ) -> Decision {
        if changeCount != ourChangeCount { return .abandon }
        if axConfirmed { return .restore }

        let evidence = readsAttributable ? reads.filter { $0 >= postedAt } : []
        guard let lastRead = evidence.max() else {
            let deadline = postedAt + evidenceWindow
            return now < deadline ? .wait(until: deadline) : .keepTranscript
        }

        let restoreAt = max(postedAt + minimumDelay, lastRead + settleAfterRead)
        return now >= restoreAt ? .restore : .wait(until: restoreAt)
    }

    /// Whether a dictation starting while a restore is still pending may keep
    /// the snapshot already taken. It may only if the clipboard still holds our
    /// transcript; otherwise the clipboard is the user's again and must be
    /// snapshotted afresh — or the transcript itself would be "restored" later.
    public static func reuseSnapshot(pendingOurChangeCount: Int?, changeCount: Int) -> Bool {
        guard let pending = pendingOurChangeCount else { return false }
        return pending == changeCount
    }
}
