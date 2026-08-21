import Foundation
import Synchronization

/// Lock-free single-producer / single-consumer ring buffer for PCM samples.
///
/// The producer is the Core Audio render thread, which must never allocate,
/// lock, or block. `write` therefore does nothing but `memcpy` into
/// preallocated storage and bump an atomic counter.
///
/// It runs **continuously**, not only while recording. That solves the preroll
/// problem: when the user presses the hotkey, the first syllable is already in
/// the buffer, so `snapshot(lastSeconds:)` recovers speech that began before the
/// press was recognized. Without this, every dictation loses its opening sound —
/// and the two-gesture design makes it worse, because a press cannot be
/// classified as hold-vs-double-tap until the double-tap window has elapsed.
public final class AudioRingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Monotonic count of samples ever written. Wraps into storage via `mask`.
    private let written = Atomic<UInt64>(0)

    public let sampleRate: Double

    /// - Parameter seconds: retained history. Rounded up to a power of two so
    ///   index wrapping is a mask rather than a modulo.
    public init(seconds: Double = 30, sampleRate: Double = 16_000) {
        let wanted = Int((seconds * sampleRate).rounded(.up))
        var size = 1
        while size < wanted { size <<= 1 }
        self.capacity = size
        self.mask = size - 1
        self.sampleRate = sampleRate
        self.storage = .allocate(capacity: size)
        self.storage.initialize(repeating: 0, count: size)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Total samples written since start. Use as a cursor.
    public var writeCursor: UInt64 { written.load(ordering: .acquiring) }

    // MARK: - Producer (real-time thread)

    /// Appends samples. **Must stay allocation-free and lock-free.**
    public func write(_ samples: UnsafeBufferPointer<Float>) {
        guard let first = samples.baseAddress, !samples.isEmpty else { return }

        // A write bigger than the ring can only leave its tail behind. Without
        // this the wrap-around copy below runs off the end of storage and
        // smashes the heap — the microphone never writes more than 4096 samples
        // at a time, so nothing hit it until a meeting session drained a
        // backlog in one go. The cursor still advances by everything written,
        // so consumers see the gap rather than a rewritten history.
        let total = samples.count
        let count = min(total, capacity)
        let base = first + (total - count)

        // The kept samples sit at absolute positions [total - count, total),
        // so they must land where a reader asking for those positions will
        // look — not at the cursor the write started from.
        let cursor = written.load(ordering: .relaxed) + UInt64(total - count)
        let start = Int(cursor & UInt64(mask))

        if start + count <= capacity {
            (storage + start).update(from: base, count: count)
        } else {
            let first = capacity - start
            (storage + start).update(from: base, count: first)
            storage.update(from: base + first, count: count - first)
        }
        written.add(UInt64(total), ordering: .releasing)
    }

    // MARK: - Consumer

    /// The most recent `seconds` of audio, or everything available if less.
    public func snapshot(lastSeconds seconds: Double) -> [Float] {
        let wanted = Int((seconds * sampleRate).rounded(.up))
        let end = writeCursor
        let available = Int(min(end, UInt64(capacity)))
        let count = min(wanted, available)
        guard count > 0 else { return [] }
        return copy(from: end - UInt64(count), count: count)
    }

    /// Samples written since `cursor`, plus the new cursor.
    ///
    /// If the producer has lapped the consumer, the oldest samples are gone;
    /// this returns what survives and reports the corrected cursor rather than
    /// silently emitting garbage.
    public func read(from cursor: UInt64) -> (samples: [Float], next: UInt64) {
        let end = writeCursor
        guard end > cursor else { return ([], end) }
        let oldest = end > UInt64(capacity) ? end - UInt64(capacity) : 0
        let start = max(cursor, oldest)
        let count = Int(end - start)
        guard count > 0 else { return ([], end) }
        return (copy(from: start, count: count), end)
    }

    /// True when the producer overwrote data the consumer had not read yet.
    public func hasOverrun(cursor: UInt64) -> Bool {
        let end = writeCursor
        return end > UInt64(capacity) && cursor < end - UInt64(capacity)
    }

    private func copy(from absolute: UInt64, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let start = Int(absolute & UInt64(mask))
        out.withUnsafeMutableBufferPointer { dst in
            guard let d = dst.baseAddress else { return }
            if start + count <= capacity {
                d.update(from: storage + start, count: count)
            } else {
                let first = capacity - start
                d.update(from: storage + start, count: first)
                (d + first).update(from: storage, count: count - first)
            }
        }
        return out
    }
}
