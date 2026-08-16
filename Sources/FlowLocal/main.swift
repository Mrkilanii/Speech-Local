import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import FlowLocalCore

// Thin entry point. The menu-bar UI arrives with M2; today this exists to make
// M0 verifiable — a signed bundle that requests its own permissions and reports
// what it sees from inside its own TCC identity.
//
// Output goes to a log file as well as stdout, because launching via Finder
// (`open`) discards stdout — and Finder launch is the only way the permission
// grant attaches to *this app* rather than to Terminal.

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/FlowLocal/doctor.log")

func log(_ line: String) {
    print(line)
    try? FileManager.default.createDirectory(
        at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = (line + "\n").data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--listen") {
    Listener.run()
    exit(0)
}

if arguments.contains("--ab") {
    await PromptAB.run()
    exit(0)
}

if arguments.contains("--probe") {
    await Probe.run()
    exit(0)
}

if arguments.contains("--request-permissions") {
    PermissionSetup.run()
    exit(0)
}

await Diagnostics.run()
exit(0)

// MARK: - Permission setup

enum PermissionSetup {
    static func run() {
        // A TCC dialog needs a WindowServer connection and a running run loop.
        // Without initializing NSApplication first, `requestAccess` returns false
        // immediately and the microphone dialog never appears — the status stays
        // `undetermined`, which looks like a denial but is not one.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        log("\n=== FlowLocal permission setup — \(Date()) ===")
        log("bundle: \(Bundle.main.bundleIdentifier ?? "NONE (not bundled!)")")

        // Shows the system Accessibility dialog. The grant lands on whichever
        // process is *responsible* — Finder-launched means FlowLocal, terminal
        // -launched means Terminal. Launch via `open`.
        // The literal, not `kAXTrustedCheckOptionPrompt`: Swift 6 rejects that
        // global as concurrency-unsafe shared mutable state. The key's value is
        // stable API.
        let options = ["AXTrustedCheckOptionPrompt": true]
        let axTrusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        log("accessibility (after prompt): \(axTrusted)")

        log("microphone status before request: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")

        // Pump the run loop while waiting so the dialog can actually render.
        var micGranted = false
        let semaphore = DispatchSemaphore(value: 0)
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            micGranted = granted
            semaphore.signal()
        }
        let deadline = Date().addingTimeInterval(120)
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        log("microphone (after requestAccess): \(micGranted)")

        // Fallback: some configurations only surface the TCC dialog on an actual
        // capture attempt, not on the requestAccess call alone.
        if !micGranted {
            log("requestAccess did not prompt — forcing a real capture attempt")
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            log("  input format: \(format.sampleRate) Hz, \(format.channelCount) ch")
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            do {
                try engine.start()
                log("  engine started")
                let until = Date().addingTimeInterval(30)
                while Date() < until,
                      AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                }
                engine.stop()
            } catch {
                log("  engine failed: \(error)")
            }
            input.removeTap(onBus: 0)
            micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            log("microphone (after capture attempt): \(micGranted)")
        }

        if !axTrusted {
            log("")
            log("Accessibility is still off. Approve FlowLocal in:")
            log("  System Settings > Privacy & Security > Accessibility")
            log("Then run 'make doctor' again.")
        }
        log("=== setup finished ===")
    }
}

// MARK: - Diagnostics

enum Diagnostics {
    static func run() async {
        var failures = 0
        func check(_ label: String, _ ok: Bool, _ detail: String = "") {
            log("  [\(ok ? "PASS" : "FAIL")] \(label)\(detail.isEmpty ? "" : " — \(detail)")")
            if !ok { failures += 1 }
        }

        log("\n=== FlowLocal diagnostics — \(Date()) ===")

        let permissions = Permissions()
        log("\nEnvironment:")
        check("running from an app bundle", permissions.isBundled,
              permissions.isBundled ? "" : "permission results are NOT trustworthy")
        log("  bundle id: \(Bundle.main.bundleIdentifier ?? "none")")
        log("  path: \(Bundle.main.bundlePath)")

        log("\nPermissions:")
        let status = permissions.status()
        check("accessibility", status.accessibility)
        check("microphone", status.microphone == .authorized, "\(status.microphone)")

        log("\nCleanup engine:")
        let engine = AppleCleanupEngine()
        switch await engine.availability() {
        case .available:
            check("FoundationModels available", true)
        case .unavailable(let reason):
            check("FoundationModels available", false, "\(reason)")
        }

        log("\nVocabulary matcher:")
        let matcher = VocabularyMatcher()
        let vocab = Vocabulary(aliases: ["kill annie": "Kilanii"])
        let got = matcher.apply(vocab, to: "ask kill annie about https://x.com/2")
        check("phrase substitution + protection",
              got == "ask Kilanii about https://x.com/2", got)

        log("")
        log(failures == 0 ? "ALL CHECKS PASS" : "\(failures) CHECK(S) FAILED")
    }
}
