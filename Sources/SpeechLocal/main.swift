import Foundation
import AppKit
import AVFoundation
import ApplicationServices
import SpeechLocalCore

// Thin entry point. The menu-bar UI arrives with M2; today this exists to make
// M0 verifiable — a signed bundle that requests its own permissions and reports
// what it sees from inside its own TCC identity.
//
// Output goes to a log file as well as stdout, because launching via Finder
// (`open`) discards stdout — and Finder launch is the only way the permission
// grant attaches to *this app* rather than to Terminal.

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/SpeechLocal/doctor.log")

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

if arguments.contains("--diagnostics") {
    await Diagnostics.run()
    exit(0)
}

if arguments.contains("--listen") {
    Listener.run()
    exit(0)
}

if arguments.contains("--ab") {
    await PromptAB.run()
    exit(0)
}

if let index = CommandLine.arguments.firstIndex(of: "--probe-meeting") {
    let next = index + 1
    let seconds = next < CommandLine.arguments.count
        ? Double(CommandLine.arguments[next]) ?? 300 : 300
    await MeetingProbe.run(seconds: seconds)
    exit(0)
}

if arguments.contains("--probe-audio-sources") {
    await AudioSourceProbe.run()
    exit(0)
}

if arguments.contains("--probe-electron") {
    ElectronProbe.run()
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

// Default: run the app. Double-clicking in Finder passes no arguments, and
// this previously fell through to a diagnostics run that wrote a log file and
// exited — so the app appeared not to open at all. Diagnostics are a flag, not
// the default behaviour.
Listener.run()
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

        log("\n=== SpeechLocal permission setup — \(Date()) ===")
        log("bundle: \(Bundle.main.bundleIdentifier ?? "NONE (not bundled!)")")

        // Shows the system Accessibility dialog. The grant lands on whichever
        // process is *responsible* — Finder-launched means SpeechLocal, terminal
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
            log("Accessibility is still off. Approve SpeechLocal in:")
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

        log("\n=== SpeechLocal diagnostics — \(Date()) ===")

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

        log("\nSpeech:")
        let asr = AppleASREngine()
        let locale = SettingsStore().current.locale
        switch await asr.availability(locale: locale) {
        case .available:
            check("ASR locale \(locale) installed", true)
        case .unavailable(let reason):
            check("ASR locale \(locale) installed", false, "\(reason)")
        }

        log("\nLight-touch regression corpus:")
        let regressions = LightTouchInvariants.check(
            using: RulesCleanup(commaPolicy:
                SettingsStore().current.commaPolicy == .sparse ? .sparse : .tidy))
        check("\(LightTouchInvariants.corpus.count) cases hold their invariants",
              regressions.isEmpty,
              regressions.isEmpty ? "" : "\(regressions.count) regression(s)")
        for failure in regressions.prefix(5) {
            log("      ✗ \(failure.note): \(failure.problem)")
            log("        in:  \(failure.input)")
            log("        out: \(failure.output)")
        }

        log("\nMachine:")
        let load = SystemLoad.oneMinute()
        log(String(format: "  load average: %.2f", load))
        if !SystemLoad.isQuietEnoughToBenchmark {
            log("  NOTE: load is above \(SystemLoad.benchmarkCeiling) — timing")
            log("        measurements taken now are not trustworthy. The same")
            log("        cleanup config measured 947 ms idle and 7 s at load 52.")
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

// MARK: - Electron accessibility probe (stage W6)

/// Claude desktop reported no focused element in 2,026 of 2,163 logged
/// insertions, so learning from edits and paste confirmation never see it.
/// Electron builds its accessibility tree only when asked, and
/// `AXManualAccessibility` is the documented way to ask. This measures whether
/// asking works, per running Electron-family app, without leaving it on.
enum ElectronProbe {
    static let candidates = ["com.anthropic.claudefordesktop", "com.openai.chat",
                             "com.openai.codex", "com.tinyspeck.slackmacgap",
                             "com.microsoft.VSCode", "company.thebrowser.Browser",
                             "com.google.Chrome"]

    static func run() {
        _ = NSApplication.shared
        log("\n=== Electron accessibility probe — \(Date()) ===")
        log("trusted: \(AXIsProcessTrusted())")
        for id in candidates {
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
            else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            let before = describe(element)
            let status = AXUIElementSetAttributeValue(
                element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            // The tree is built asynchronously; give it a moment.
            let treeBefore = census(element)
            RunLoop.current.run(until: Date().addingTimeInterval(3.0))
            let after = describe(element)
            log("\(id): before [\(before)] tree [\(treeBefore)]  set=\(status.rawValue)")
            log("    after [\(after)] tree [\(census(element))]")
            if !CommandLine.arguments.contains("--keep") {
                AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanFalse)
            }
        }
        log("=== probe finished ===")
    }

    /// How many elements the app's windows expose, and how many of them are
    /// text areas with readable text. A tree Electron has not built is a few
    /// nodes; a built one is hundreds.
    static func census(_ app: AXUIElement) -> String {
        var nodes = 0, textAreas = 0, readable = 0
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 40, nodes < 5000 else { return }
            nodes += 1
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
            if let role = role as? String, role == "AXTextArea" || role == "AXTextField" {
                textAreas += 1
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
                   value is String { readable += 1 }
            }
            var children: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
                  let list = children as? [AXUIElement] else { return }
            for child in list { walk(child, depth: depth + 1) }
        }
        var windows: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
           let list = windows as? [AXUIElement] {
            for window in list { walk(window, depth: 0) }
        }
        return "nodes=\(nodes) text=\(textAreas) readable=\(readable)"
    }

    /// Focused element's role, and how much text it exposes.
    static func describe(_ app: AXUIElement) -> String {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused else { return "no focused element" }
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var value: CFTypeRef?
        let read = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        let length = (value as? String)?.count ?? -1
        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable)
        return "role=\(role as? String ?? "?") valueRead=\(read == .success) len=\(length) selSettable=\(settable.boolValue)"
    }
}

