import Foundation
import AppKit
import ApplicationServices

/// Watches for machine states that make an in-flight dictation invalid.
///
/// Audio capture stops when the machine sleeps, but the gesture does not: the
/// key is still logically held, the ring buffer still holds what was said
/// before the lid closed, and releasing the key on wake would transcribe stale
/// audio and insert it wherever the cursor now happens to be — possibly hours
/// later, in a different app.
///
/// So a dictation interrupted by sleep, screen lock, or user switching is
/// abandoned rather than resumed. The user has left; whatever they were saying
/// is no longer wanted where they are now.
public final class LifecycleMonitor: @unchecked Sendable {
    /// Called with a human-readable reason when the current dictation must end.
    public var onInterrupt: (@Sendable (String) -> Void)?

    /// Called when Accessibility is revoked while the app is running.
    ///
    /// macOS kills the event tap and `CGEvent.tapEnable` then fails silently, so
    /// the app keeps running with hotkeys that do nothing and no way for the
    /// user to tell whether it is broken or they are mis-pressing. Polling is
    /// the only option: there is no notification for a revoked TCC grant.
    public var onAccessibilityLost: (@Sendable () -> Void)?
    /// Called when it is granted again, so the app can recover without a restart.
    public var onAccessibilityRestored: (@Sendable () -> Void)?

    private var tokens: [NSObjectProtocol] = []
    private var distributedTokens: [NSObjectProtocol] = []
    private var permissionTimer: Timer?
    private var lastTrusted = true

    public init() {}

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter

        let workspaceEvents: [(NSNotification.Name, String)] = [
            (NSWorkspace.willSleepNotification, "the machine went to sleep"),
            (NSWorkspace.screensDidSleepNotification, "the display slept"),
            (NSWorkspace.sessionDidResignActiveNotification, "the user session switched"),
        ]

        for (name, reason) in workspaceEvents {
            let token = workspace.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.onInterrupt?(reason)
            }
            tokens.append(token)
        }

        // Screen lock has no AppKit notification; it is only published on the
        // distributed centre.
        let distributed = DistributedNotificationCenter.default()
        let lockToken = distributed.addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            self?.onInterrupt?("the screen locked")
        }
        distributedTokens.append(lockToken)

        lastTrusted = AXIsProcessTrusted()
        permissionTimer = Timer.scheduledTimer(
            withTimeInterval: 2.0, repeats: true
        ) { [weak self] _ in
            guard let self else { return }
            let trusted = AXIsProcessTrusted()
            guard trusted != self.lastTrusted else { return }
            self.lastTrusted = trusted
            if trusted {
                self.onAccessibilityRestored?()
            } else {
                self.onInterrupt?("Accessibility was turned off")
                self.onAccessibilityLost?()
            }
        }
    }

    public func stop() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        let workspace = NSWorkspace.shared.notificationCenter
        tokens.forEach { workspace.removeObserver($0) }
        tokens.removeAll()
        let distributed = DistributedNotificationCenter.default()
        distributedTokens.forEach { distributed.removeObserver($0) }
        distributedTokens.removeAll()
    }

    deinit { stop() }
}
