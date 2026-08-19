import Foundation
import SpeechLocalCore

// A headless transcriber: raw PCM in on stdin, one transcript out on stdout.
//
// Added so Jarvis (a separate Electron app) can use this engine instead of
// whisper.cpp. Deliberately a SEPARATE executable target rather than another
// flag on the menu-bar app: that binary is wrapped in a signed .app with its own
// TCC identity, and nothing about a second process spawning it headlessly should
// be able to disturb that.
//
// ── Why stdin rather than a file path ─────────────────────────────────────
//
// Jarvis's existing whisper adapter has to write a WAV to a temp directory,
// because whisper.cpp cannot read a pipe — and its own acceptance criteria call
// that "the only moment raw audio exists on disk in this app". Reading from a
// pipe removes that moment entirely. The audio lives in two process memories and
// is gone when this exits.
//
// ── Input format ──────────────────────────────────────────────────────────
//
// Signed 16-bit little-endian mono PCM, which is what a browser AudioContext
// gives after the usual Float32 → Int16 conversion, and what Jarvis already
// carries internally. Sample rate is passed in rather than guessed.
//
//   swift run SpeechLocalStdin --sample-rate 16000 --locale en-US < clip.pcm
//
// `--bias` takes a comma-separated vocabulary hint. It exists for the correction
// loop: words Omar has fixed before are the words most worth biasing toward.

struct Options {
    var sampleRate: Double = 16_000
    var locale: String = "en-US"
    var bias: [String] = []
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let flag = arguments[index]
        let value = index + 1 < arguments.count ? arguments[index + 1] : nil
        switch flag {
        case "--sample-rate":
            if let value, let rate = Double(value) { options.sampleRate = rate }
            index += 2
        case "--locale":
            if let value { options.locale = value }
            index += 2
        case "--bias":
            // Empty entries dropped: a trailing comma is a typo, not a term.
            if let value {
                options.bias = value.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            index += 2
        default:
            index += 1
        }
    }
    return options
}

/// Read stdin to the end, in chunks, so a long clip does not depend on one read.
func readAllStdin() -> Data {
    var data = Data()
    while true {
        let chunk = FileHandle.standardInput.availableData
        if chunk.isEmpty { break }
        data.append(chunk)
    }
    return data
}

/// Signed 16-bit little-endian → normalised float, which is what the engine takes.
func samples(from data: Data) -> [Float] {
    let count = data.count / 2
    var out = [Float](repeating: 0, count: count)
    data.withUnsafeBytes { raw in
        for i in 0..<count {
            // Read byte-wise rather than binding to Int16: the buffer is not
            // guaranteed to be 2-byte aligned, and an unaligned load is
            // undefined rather than merely slow.
            let low = UInt16(raw[i * 2])
            let high = UInt16(raw[i * 2 + 1])
            let value = Int16(bitPattern: low | (high << 8))
            out[i] = Float(value) / 32_768
        }
    }
    return out
}

let options = parse(Array(CommandLine.arguments.dropFirst()))
let audio = samples(from: readAllStdin())

if audio.isEmpty {
    // Nothing heard is not an error, and must not be reported as one — the
    // caller treats a non-zero exit as "the engine is broken".
    print("")
    exit(0)
}

let engine = AppleASREngine()

switch await engine.availability(locale: options.locale) {
case .available:
    break
case .unavailable(let reason):
    FileHandle.standardError.write(Data("unavailable: \(reason)\n".utf8))
    exit(2)
}

do {
    let text = try await engine.transcribe(
        samples: audio,
        sampleRate: options.sampleRate,
        locale: options.locale,
        biasTerms: options.bias
    )
    print(text)
    exit(0)
} catch {
    FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
    exit(1)
}
