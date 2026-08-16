import Foundation
import AVFoundation
import ApplicationServices

/// Read-only permission inspection.
///
/// **Nothing here prompts.** Requesting a grant is a deliberate, user-facing act
/// that belongs in the app's onboarding flow, not in a status check that may run
/// on a timer.
///
/// ⚠️ **These results are only meaningful from inside the signed `.app`.**
/// `AXIsProcessTrusted()` returns `true` for a binary launched from a terminal
/// because it inherits the *terminal's* Accessibility grant. Verified during
/// research: a bare CLI reported trusted while no such grant existed for the
/// app. Never validate permissions from a shell — you will be told what you want
/// to hear.
public struct Permissions: Sendable {
    public init() {}

    public struct Status: Sendable, Equatable {
        public let accessibility: Bool
        public let microphone: MicrophoneStatus

        public var allGranted: Bool { accessibility && microphone == .authorized }
    }

    public enum MicrophoneStatus: Sendable, Equatable {
        case authorized, denied, undetermined, restricted
    }

    public func status() -> Status {
        Status(accessibility: AXIsProcessTrusted(), microphone: microphoneStatus())
    }

    private func microphoneStatus() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .authorized
        case .denied: return .denied
        case .notDetermined: return .undetermined
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    /// True when the process is running from an app bundle rather than as a bare
    /// executable. Permission results from a non-bundled process are not
    /// trustworthy, and `NSStatusBar` will crash outright.
    public var isBundled: Bool {
        Bundle.main.bundleIdentifier != nil
    }
}
