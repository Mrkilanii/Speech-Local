import Foundation
import AVFoundation
import Speech

/// Transcription via Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// Chosen over Parakeet/WhisperKit because it needs **no model download**
/// (`en-US` ships installed), works with Apple Intelligence switched off, and
/// removes the entire model-management subsystem — no checksums, no staging, no
/// version migration. Verified on-device only: the framework has no server path.
public actor AppleASREngine: ASREngine {
    public enum TranscribeError: Error, Sendable {
        case localeNotInstalled(String)
        case formatUnavailable
        case conversionFailed
    }

    public init() {}

    // MARK: - Availability

    public func availability(locale identifier: String) async -> ASRAvailability {
        let target = Locale(identifier: identifier)
        let supported = await SpeechTranscriber.supportedLocales
        let installed = await SpeechTranscriber.installedLocales

        func matches(_ list: [Locale]) -> Bool {
            list.contains { $0.identifier(.bcp47) == target.identifier(.bcp47) }
        }

        if matches(installed) { return .available }
        if matches(supported) { return .unavailable(.localeNotInstalled(identifier)) }
        return .unavailable(.localeUnsupported(identifier))
    }

    public static func installedLocaleIdentifiers() async -> [String] {
        await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
    }

    // MARK: - Transcription

    public nonisolated func transcribe(
        audio: AsyncStream<AudioChunk>,
        locale: String
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let text = try await self.run(audio: audio, locale: locale) { partial in
                        continuation.yield(partial)
                    }
                    continuation.yield(text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience for the hold gesture, where the whole clip is available at
    /// once. Still runs through the streaming analyzer underneath.
    public func transcribe(samples: [Float], sampleRate: Double, locale: String) async throws -> String {
        let stream = AsyncStream<AudioChunk> { continuation in
            continuation.yield(AudioChunk(samples: samples, sampleRate: sampleRate))
            continuation.finish()
        }
        return try await run(audio: stream, locale: locale) { _ in }
    }

    private func run(
        audio: AsyncStream<AudioChunk>,
        locale identifier: String,
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let locale = Locale(identifier: identifier)
        let installed = await SpeechTranscriber.installedLocales
        guard installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) else {
            throw TranscribeError.localeNotInstalled(identifier)
        }

        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

        // The analyzer dictates its own preferred format; our ring buffer is
        // 16 kHz mono, so a second conversion is generally required.
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [transcriber]
        ) else { throw TranscribeError.formatUnavailable }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        // Collect results concurrently: the analyzer will not finish until its
        // input ends, and results arrive while that happens.
        let collector = Task {
            var best = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if !text.isEmpty {
                    best = text
                    onPartial(text)
                }
            }
            return best
        }

        try await analyzer.start(inputSequence: inputStream)

        for await chunk in audio {
            try Task.checkCancellation()
            guard let buffer = Self.makeBuffer(
                samples: chunk.samples, sampleRate: chunk.sampleRate, target: analyzerFormat
            ) else { throw TranscribeError.conversionFailed }
            inputContinuation.yield(AnalyzerInput(buffer: buffer))
        }
        inputContinuation.finish()

        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value
    }

    // MARK: - Format conversion

    /// Converts raw mono float samples into the analyzer's required format.
    nonisolated static func makeBuffer(
        samples: [Float],
        sampleRate: Double,
        target: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let sourceFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: 1,
                interleaved: false)
        else { return nil }

        guard let source = AVAudioPCMBuffer(
            pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)
        ) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress, let dst = source.floatChannelData?[0] else { return }
            dst.update(from: base, count: samples.count)
        }

        if sourceFormat == target { return source }

        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { return nil }
        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            return nil
        }

        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return source
        }
        guard status == .haveData || status == .inputRanDry, output.frameLength > 0 else {
            return nil
        }
        return output
    }
}
