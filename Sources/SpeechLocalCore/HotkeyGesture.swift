import Foundation

/// Pure state machine for the two-gesture hotkey, kept free of Core Graphics so
/// it can be tested with synthetic timings instead of real key events.
///
/// The hard part: **a key-down is ambiguous.** It might begin a hold, or it
/// might be the first half of a double-tap. It cannot be classified until either
/// the key is released or the hold threshold passes. Recording therefore starts
/// optimistically on the first key-down and is retroactively reinterpreted —
/// which is why `AudioRingBuffer` runs continuously.
public struct HotkeyGesture: Sendable {
    public enum Mode: Sendable, Equatable { case hold, toggle }

    public enum Event: Sendable, Equatable {
        case keyDown(at: TimeInterval)
        case keyUp(at: TimeInterval)
        /// Autorepeat. Ignored — holding a key emits a stream of these and each
        /// one would otherwise look like a fresh press.
        case keyRepeat
        case tick(at: TimeInterval)
    }

    public enum Action: Sendable, Equatable {
        case beginRecording(Mode)
        case finishRecording(Mode)
        /// The press turned out to be the first tap of a double-tap. Discard
        /// what was captured and start clean.
        case discardAndRestart
        case none
    }

    public enum State: Sendable, Equatable {
        case idle
        /// Key down, not yet classified.
        case pendingFirstPress(downAt: TimeInterval)
        /// Held past the threshold — committed to hold mode.
        case holding
        /// Released quickly; waiting to see whether a second tap arrives.
        case awaitingSecondTap(releasedAt: TimeInterval)
        /// Double-tap latched; recording until the next tap.
        case toggled
    }

    /// Press longer than this is a hold, not a tap.
    public var holdThreshold: TimeInterval = 0.25
    /// Second tap must land within this of the first release.
    public var doubleTapWindow: TimeInterval = 0.35
    /// Hands-free sessions cannot grow without bound.
    public var maxToggleDuration: TimeInterval = 300

    public private(set) var state: State = .idle
    private var toggleStartedAt: TimeInterval = 0

    public init() {}

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {

        // Autorepeat is never meaningful here.
        case (_, .keyRepeat):
            return .none

        case (.idle, .keyDown(let at)):
            state = .pendingFirstPress(downAt: at)
            return .beginRecording(.hold)   // optimistic; may be revised

        case (.pendingFirstPress(let downAt), .tick(let now))
             where now - downAt >= holdThreshold:
            state = .holding
            return .none                     // hold confirmed, keep recording

        case (.pendingFirstPress(let downAt), .keyUp(let at)):
            if at - downAt >= holdThreshold {
                state = .idle
                return .finishRecording(.hold)
            }
            state = .awaitingSecondTap(releasedAt: at)
            return .none                     // hold the audio; verdict pending

        case (.holding, .keyUp):
            state = .idle
            return .finishRecording(.hold)

        // Second tap inside the window: it was a double-tap all along.
        case (.awaitingSecondTap(let releasedAt), .keyDown(let at))
             where at - releasedAt <= doubleTapWindow:
            state = .toggled
            toggleStartedAt = at
            return .discardAndRestart

        // Window expired: it really was a short hold. Emit what we captured.
        case (.awaitingSecondTap(let releasedAt), .tick(let now))
             where now - releasedAt > doubleTapWindow:
            state = .idle
            return .finishRecording(.hold)

        // A late key-down after the window is simply a new gesture.
        case (.awaitingSecondTap, .keyDown(let at)):
            state = .pendingFirstPress(downAt: at)
            return .finishRecording(.hold)

        case (.toggled, .keyDown):
            state = .idle
            return .finishRecording(.toggle)

        case (.toggled, .tick(let now))
             where now - toggleStartedAt >= maxToggleDuration:
            state = .idle
            return .finishRecording(.toggle)

        default:
            return .none
        }
    }

    /// External abort: permission revoked, sleep, screen lock, audio route
    /// change, tap disabled. Returns the action needed to unwind cleanly.
    public mutating func abort() -> Action {
        let wasRecording: Mode?
        switch state {
        case .idle: wasRecording = nil
        case .toggled: wasRecording = .toggle
        default: wasRecording = .hold
        }
        state = .idle
        return wasRecording.map { .finishRecording($0) } ?? .none
    }

    /// True whenever audio is being retained for a gesture in progress —
    /// including `awaitingSecondTap`, where the verdict is pending but the
    /// captured audio must not be dropped yet.
    public var isRecording: Bool {
        switch state {
        case .idle: return false
        case .pendingFirstPress, .holding, .awaitingSecondTap, .toggled: return true
        }
    }
}
