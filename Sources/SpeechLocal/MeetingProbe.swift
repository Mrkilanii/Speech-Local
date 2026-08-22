import Foundation
import AppKit
import Darwin
import SpeechLocalCore

/// Runs a real meeting session against the real recognizer and watches memory.
///
///     open dist/SpeechLocal.app --args --probe-meeting 300
///
/// This is the only claim in the feature that a unit test cannot make. The
/// dictation path holds its recording as `[Float]` — 230 MB an hour, and a
/// second copy every time it measures the level — which is why it is capped at
/// five minutes. `MeetingSession` is supposed to hold no audio at all, so
/// resident memory should sit flat however long it runs. If it climbs, the rest
/// of the feature is built on sand.
enum MeetingProbe {
    static func run(seconds: Double) async {
        // Before any CoreAudio call. A process tap needs a WindowServer
        // connection for TCC to attribute it to this bundle — the audio-source
        // spike does this and captures; the first version of this probe did
        // not, and its tap started cleanly, reported no error, and delivered
        // zero buffers for three minutes.
        await MainActor.run {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
        }

        log("=== meeting session probe ===")
        log("target: \(Int(seconds))s — the old hands-free cap was 300s")

        let capture: AudioCapture
        do {
            capture = try AudioCapture()
            try capture.start()
        } catch {
            log("FAILED to start audio capture: \(error)")
            return
        }
        defer { capture.stop() }

        // The other side of a call. Without this the probe only proves the
        // microphone works, which was never in doubt — and a mic hearing the
        // speakers across the room looks deceptively like a working tap.
        var systemBuffer: AudioRingBuffer?
        var tap: SystemAudioTap?
        do {
            let started = try SystemAudioTap()
            try started.start()
            tap = started
            systemBuffer = started.buffer
            log("system audio: capturing")
            log("  \(started.diagnostics)")
        } catch {
            log("system audio: UNAVAILABLE (\(error)) — microphone only")
        }
        defer { tap?.stop() }

        let settings = SettingsStore()
        let session = MeetingSession(
            engine: AppleASREngine(),
            buffer: capture.buffer,
            systemBuffer: systemBuffer,
            locale: settings.current.locale)

        let baseline = residentMB()
        log(String(format: "baseline resident: %.1f MB", baseline))
        await session.start()

        var samples: [(t: Double, mb: Double)] = []
        let started = Date()
        while Date().timeIntervalSince(started) < seconds {
            try? await Task.sleep(for: .seconds(15))
            let elapsed = Date().timeIntervalSince(started)
            let mb = residentMB()
            samples.append((elapsed, mb))
            let captured = await session.secondsCaptured
            let length = await session.transcript.count
            // Level per source, so a silent tap is visible rather than hidden
            // behind a microphone that is doing all the work.
            let micLevel = level(capture.buffer)
            let systemLevel = systemBuffer.map(level) ?? 0
            log(String(format: "  %5.0fs  resident %6.1f MB  (%+.1f)  audio %5.0fs  "
                       + "mic %.4f  system %.4f (%d buffers)  transcript %d chars",
                       elapsed, mb, mb - baseline, captured,
                       micLevel, systemLevel, tap?.deliveredBuffers ?? 0, length))
        }

        await session.stop()
        let final = residentMB()

        log("")
        log(String(format: "final resident: %.1f MB  (+%.1f from baseline)", final, final - baseline))
        // A slope needs a window long enough that ordinary allocator noise is
        // not the whole signal. Two samples 16 s apart extrapolate a 1.4 MB
        // wobble into "+330 MB/hour" and call it a leak.
        guard let first = samples.first, let last = samples.last,
              last.t - first.t >= 120 else {
            log("run was too short to judge a trend — use 300s or more")
            let text = await session.transcript
            log("transcript (\(text.count) chars): \(text.prefix(300))")
            return
        }
        if last.t > first.t {
            let perHour = (last.mb - first.mb) / (last.t - first.t) * 3600
            log(String(format: "slope: %+.1f MB/hour", perHour))
            log(perHour < 60
                ? "FLAT ENOUGH — an hour fits well inside the audio the old path would have held"
                : "CLIMBING — something is retaining audio; do not build on this")
        }
        let text = await session.transcript
        log("transcript (\(text.count) chars): \(text.prefix(300))")
        log("audio lost to overrun: \(await session.didLoseAudio)")
    }

    /// RMS of the last second, so each source can be seen to be carrying audio.
    private static func level(_ buffer: AudioRingBuffer) -> Double {
        let samples = buffer.snapshot(lastSeconds: 1)
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1 * $1) }
        return (sum / Double(samples.count)).squareRoot()
    }

    /// Resident size of this process, the number Activity Monitor shows.
    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}
