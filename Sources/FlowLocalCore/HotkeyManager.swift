import Foundation
import CoreGraphics
import ApplicationServices

/// Global hotkey monitoring via a `CGEventTap`.
///
/// **The callback runs inline on every keystroke the user types, system-wide.**
/// Anything slow there degrades typing for the whole machine, and if the tap
/// exceeds its time budget macOS disables it outright. So the callback does the
/// minimum: read a keycode, hand it to a lock-free queue, return. All
/// interpretation happens on a serial dispatch queue.
public final class HotkeyManager: @unchecked Sendable {
    /// Modifier keys, identified by keycode. Modifiers arrive as
    /// `.flagsChanged`, never as key-down/up, so press and release must be
    /// derived from whether the flag is now set.
    public struct Key: Sendable, Equatable {
        public let keyCode: CGKeyCode
        public let flag: CGEventFlags
        public let name: String

        public static let rightOption = Key(keyCode: 61, flag: .maskAlternate, name: "Right Option")
        public static let rightCommand = Key(keyCode: 54, flag: .maskCommand, name: "Right Command")
        public static let rightControl = Key(keyCode: 62, flag: .maskControl, name: "Right Control")
        public static let fn = Key(keyCode: 63, flag: .maskSecondaryFn, name: "Fn")
    }

    public enum Signal: Sendable {
        case gesture(CleanupMode, HotkeyGesture.Action)
        /// The tap was disabled by the system. Recording must abort — keys are
        /// no longer observed, so a hold can never be seen to end.
        case tapDisabled(String)
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let queue = DispatchQueue(label: "dev.kilanii.flowlocal.hotkey")

    private var bindings: [CGKeyCode: CleanupMode] = [:]
    private var gestures: [CleanupMode: HotkeyGesture] = [:]
    private var ticker: DispatchSourceTimer?

    public var onSignal: (@Sendable (Signal) -> Void)?

    /// Tag stamped on our own synthetic events so the abort guard can ignore
    /// them. Without this the app aborts its own dictation the instant it
    /// synthesizes ⌘V to paste the result.
    public static let syntheticEventTag: Int64 = 0x464C4F57  // "FLOW"
    private static let syntheticEventField = CGEventField.eventSourceUserData

    public init(lightTouch: Key = .rightOption, fullRewrite: Key = .rightCommand) {
        bindings[lightTouch.keyCode] = .lightTouch
        bindings[fullRewrite.keyCode] = .fullRewrite
        gestures[.lightTouch] = HotkeyGesture()
        gestures[.fullRewrite] = HotkeyGesture()
    }

    // MARK: - Lifecycle

    public enum StartError: Error, Sendable {
        case accessibilityDenied
        case tapCreationFailed
    }

    public func start() throws {
        guard AXIsProcessTrusted() else { throw StartError.accessibilityDenied }

        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.tapDisabledByTimeout.rawValue)
                 | (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            // Listen-only: the app must never swallow keystrokes. A defaultTap
            // that hangs would freeze typing machine-wide.
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                manager.handleFromTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else { throw StartError.tapCreationFailed }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        startTicker()
    }

    public func stop() {
        ticker?.cancel()
        ticker = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: - Tap callback (hot path — keep this trivial)

    private func handleFromTap(type: CGEventType, event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Re-enabling is safe here and must happen, or hotkeys silently die
            // for the rest of the session.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            queue.async { [weak self] in self?.abortAll(reason: "event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input")") }
            return

        case .flagsChanged, .keyDown, .keyUp:
            // Ignore events we synthesized ourselves.
            if event.getIntegerValueField(Self.syntheticEventField) == Self.syntheticEventTag { return }

            let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
            guard let mode = bindings[keyCode] else { return }

            let isDown: Bool
            if type == .flagsChanged {
                isDown = Self.flagIsSet(for: keyCode, in: event.flags)
            } else {
                // Autorepeat: holding a key emits repeated key-downs, each of
                // which would otherwise read as a fresh press.
                if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 { return }
                isDown = (type == .keyDown)
            }

            let now = Date().timeIntervalSinceReferenceDate
            queue.async { [weak self] in
                self?.process(mode: mode, event: isDown ? .keyDown(at: now) : .keyUp(at: now))
            }

        default:
            return
        }
    }

    private static func flagIsSet(for keyCode: CGKeyCode, in flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 61, 58: return flags.contains(.maskAlternate)
        case 54, 55: return flags.contains(.maskCommand)
        case 62, 59: return flags.contains(.maskControl)
        case 63:     return flags.contains(.maskSecondaryFn)
        case 60, 56: return flags.contains(.maskShift)
        default:     return false
        }
    }

    // MARK: - Serial interpretation

    /// Drives the pending-gesture timers. A press that is never released — or a
    /// double-tap window that simply expires — needs a tick to resolve.
    private func startTicker() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 0.05)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Date().timeIntervalSinceReferenceDate
            for mode in self.gestures.keys {
                self.process(mode: mode, event: .tick(at: now))
            }
        }
        timer.resume()
        ticker = timer
    }

    private func process(mode: CleanupMode, event: HotkeyGesture.Event) {
        guard var gesture = gestures[mode] else { return }
        let action = gesture.handle(event)
        gestures[mode] = gesture
        guard action != .none else { return }
        onSignal?(.gesture(mode, action))
    }

    private func abortAll(reason: String) {
        for mode in gestures.keys {
            guard var gesture = gestures[mode] else { continue }
            let action = gesture.abort()
            gestures[mode] = gesture
            if action != .none { onSignal?(.gesture(mode, action)) }
        }
        onSignal?(.tapDisabled(reason))
    }
}
