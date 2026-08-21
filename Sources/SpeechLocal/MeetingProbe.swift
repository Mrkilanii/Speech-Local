import Foundation
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

        let settings = SettingsStore()
        let session = MeetingSession(
            engine: AppleASREngine(),
            buffer: capture.buffer,
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
            log(String(format: "  %5.0fs  resident %6.1f MB  (+%.1f)  audio %5.0fs  transcript %d chars",
                       elapsed, mb, mb - baseline, captured, length))
        }

        await session.stop()
        let final = residentMB()

        log("")
        log(String(format: "final resident: %.1f MB  (+%.1f from baseline)", final, final - baseline))
        if let first = samples.first, let last = samples.last, last.t > first.t {
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
