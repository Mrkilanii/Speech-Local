import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Transcription via Apple's on-device `SpeechAnalyzer` / `SpeechTranscriber`.
///
/// Chosen over Parakeet/WhisperKit because it needs **no model download**
/// (`en-US` ships installed), works with Apple Intelligence switched off, and
/// removes the entire model-management subsystem — no checksums, no staging, no
/// version migration. Verified on-device only: the framework has no server path.
public actor AppleASREngine: ASREngine {
    public enum TranscribeError: Error, Sendable {
        case localeNotInstalled(String)
        case localeUnsupported(String)
        case formatUnavailable
        case conversionFailed
        case assetInstallFailed(String)
    }

    /// Apple ships two transcription modules with **different language
    /// coverage**, and neither is a superset of the other in practice:
    ///
    /// * `SpeechTranscriber` — 30 locales (en, de, es, fr, it, ja, ko, pt, zh,
    ///   yue). Long-form, and the better engine where it is available.
    /// * `DictationTranscriber` — 54 locales, including Arabic, Hebrew, Hindi,
    ///   Polish, Turkish and others `SpeechTranscriber` simply does not do.
    ///
    /// Arabic is the case that forced this: `SpeechTranscriber.supportedLocales`
    /// does not contain `ar-SA` at all, so no amount of downloading would have
    /// made it work. The engine therefore picks per locale, preferring
    /// `SpeechTranscriber` and falling back to `DictationTranscriber`.
    enum Module {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var speechModule: any SpeechModule {
            switch self {
            case .speech(let module):    return module
            case .dictation(let module): return module
            }
        }
    }

    static func module(for locale: Locale) async -> Module? {
        let bcp = locale.identifier(.bcp47)
        func matches(_ list: [Locale]) -> Bool {
            list.contains { $0.identifier(.bcp47) == bcp }
        }

        if matches(await SpeechTranscriber.supportedLocales) {
            return .speech(SpeechTranscriber(locale: locale, preset: .progressiveTranscription))
        }
        if matches(await DictationTranscriber.supportedLocales) {
            return .dictation(DictationTranscriber(
                locale: locale,
                contentHints: [],
                transcriptionOptions: [.punctuation],
                reportingOptions: [],
                attributeOptions: []))
        }
        return nil
    }

    /// Every locale either module can handle, for the settings picker.
    public static func allSupportedLocaleIdentifiers() async -> [String] {
        let speech = await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        let dictation = await DictationTranscriber.supportedLocales.map { $0.identifier(.bcp47) }
        return Array(Set(speech).union(dictation)).sorted()
    }

    /// Locales ready to use without a download.
    public static func installedLocaleIdentifiers() async -> [String] {
        let speech = await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        let dictation = await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) }
        return Array(Set(speech).union(dictation)).sorted()
    }

    /// Downloads the assets a locale needs, if any.
    ///
    /// Supported does not imply installed: `ar-SA` is listed by
    /// `DictationTranscriber` while its assets are absent, and transcription
    /// fails until they are fetched.
    public static func installAssets(for identifier: String) async throws {
        let locale = Locale(identifier: identifier)
        guard let module = await module(for: locale) else {
            throw TranscribeError.localeUnsupported(identifier)
        }
        _ = try? await AssetInventory.reserve(locale: locale)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(
                supporting: [module.speechModule]
            ) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscribeError.assetInstallFailed("\(error)")
        }
    }

    public init() {}

    // MARK: - Availability

    public func availability(locale identifier: String) async -> ASRAvailability {
        let installed = await Self.installedLocaleIdentifiers()
        if installed.contains(identifier) { return .available }
        let supported = await Self.allSupportedLocaleIdentifiers()
        if supported.contains(identifier) {
            return .unavailable(.localeNotInstalled(identifier))
        }
        return .unavailable(.localeUnsupported(identifier))
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
    public func transcribe(
        samples: [Float],
        sampleRate: Double,
        locale: String,
        biasTerms: [String] = []
    ) async throws -> String {
        let stream = AsyncStream<AudioChunk> { continuation in
            continuation.yield(AudioChunk(samples: samples, sampleRate: sampleRate))
            continuation.finish()
        }
        return try await run(audio: stream, locale: locale, biasTerms: biasTerms) { _ in }
    }

    private func run(
        audio: AsyncStream<AudioChunk>,
        locale identifier: String,
        biasTerms: [String] = [],
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> String {
        let locale = Locale(identifier: identifier)
        guard let module = await Self.module(for: locale) else {
            throw TranscribeError.localeUnsupported(identifier)
        }

        let installed = await Self.installedLocaleIdentifiers()
        guard installed.contains(locale.identifier(.bcp47)) else {
            throw TranscribeError.localeNotInstalled(identifier)
        }

        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: [module.speechModule]
        ) else { throw TranscribeError.formatUnavailable }

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

        // Learned corrections bias the recognizer toward words the user has
        // fixed before. Strictly safer than rewriting output: it nudges
        // recognition and cannot corrupt an otherwise-correct transcript.
        let context = AnalysisContext()
        if !biasTerms.isEmpty {
            context.contextualStrings[.general] = biasTerms
        }

        let analyzer = SpeechAnalyzer(
            inputSequence: inputStream,
            modules: [module.speechModule],
            analysisContext: context
        )

        // Results are per-SEGMENT, not cumulative: each carries its own
        // CMTimeRange, and a segment is finalized whenever the speaker pauses.
        // Assigning each result to one variable kept only the last sentence of a
        // paragraph. A later result for a range already seen supersedes it —
        // that is how a volatile segment becomes its finalized version.
        //
        // The two modules publish different Result types, so the accumulation is
        // shared and only the iteration differs.
        actor Segments {
            private var items: [(start: CMTime, text: String)] = []

            func add(start: CMTime, text: String) -> String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return assembled() }
                if let index = items.firstIndex(where: { $0.start == start }) {
                    items[index].text = trimmed
                } else {
                    items.append((start: start, text: trimmed))
                    items.sort { $0.start < $1.start }
                }
                return assembled()
            }

            func assembled() -> String {
                items.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
            }
        }
        let segments = Segments()

        let collector = Task { () -> String in
            switch module {
            case .speech(let transcriber):
                for try await result in transcriber.results {
                    let text = await segments.add(
                        start: result.range.start, text: String(result.text.characters))
                    onPartial(text)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    let text = await segments.add(
                        start: result.range.start, text: String(result.text.characters))
                    onPartial(text)
                }
            }
            return await segments.assembled()
        }

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
