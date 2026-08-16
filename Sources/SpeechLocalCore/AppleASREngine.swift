import Foundation
import AVFoundation
import Speech
import CoreMedia

/// Assembles transcriber results into one transcript.
///
/// Results are per-**segment**, not cumulative: each carries its own
/// `CMTimeRange`, and a segment is finalized whenever the speaker pauses.
/// Assigning each result to one variable kept only the last sentence of a
/// paragraph, so they have to be accumulated.
///
/// The subtlety is that the same audio is reported more than once. A segment
/// arrives *volatile* while the analyzer is still guessing, then again
/// finalized, and the finalized range need not start where the volatile one
/// did — the analyzer re-segments as it gains context. Keying on the start time
/// alone therefore filed the two as different segments, and a dictated "2052"
/// came back as "2052. 2052.".
///
/// So: only finalized results are kept, and a finalized result evicts anything
/// it overlaps. Volatile text is held separately for the live preview, where
/// being provisional is the point.
struct TranscriptAssembler {
    private var finals: [(range: CMTimeRange, text: String)] = []
    private var pending = ""

    mutating func add(range: CMTimeRange, text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isFinal else {
            pending = trimmed
            return
        }
        // Anything this segment covers has been superseded by it.
        finals.removeAll { !$0.range.intersection(range).isEmpty }
        pending = ""
        guard !trimmed.isEmpty else { return }
        finals.append((range: range, text: trimmed))
        finals.sort { $0.range.start < $1.range.start }
    }

    /// Everything settled so far. The transcript the user gets.
    var finalized: String {
        finals.map(\.text).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Settled text plus the current guess, for on-screen feedback only.
    var live: String {
        (finals.map(\.text) + [pending]).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

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

        // The two modules publish different Result types, so the accumulation is
        // shared (see `TranscriptAssembler`) and only the iteration differs.
        actor Segments {
            private var assembler = TranscriptAssembler()

            func add(range: CMTimeRange, text: String, isFinal: Bool) -> String {
                assembler.add(range: range, text: text, isFinal: isFinal)
                return assembler.live
            }

            func finalized() -> String { assembler.finalized }
        }
        let segments = Segments()

        let collector = Task { () -> String in
            switch module {
            case .speech(let transcriber):
                for try await result in transcriber.results {
                    let text = await segments.add(
                        range: result.range, text: String(result.text.characters),
                        isFinal: result.isFinal)
                    onPartial(text)
                }
            case .dictation(let transcriber):
                for try await result in transcriber.results {
                    let text = await segments.add(
                        range: result.range, text: String(result.text.characters),
                        isFinal: result.isFinal)
                    onPartial(text)
                }
            }
            return await segments.finalized()
        }

        // Feed the analyzer in slices rather than one buffer.
        //
        // A 5-minute hands-free session handed over as a single 4.8M-sample
        // buffer came back with six words. The analyzer is designed for a
        // stream: given one enormous input it does not segment it usefully.
        // Slicing restores the pacing it expects and lets partial results
        // arrive while the rest is still being fed.
        let sliceSeconds = 10.0
        for await chunk in audio {
            try Task.checkCancellation()
            let perSlice = Int(sliceSeconds * chunk.sampleRate)
            var offset = 0
            while offset < chunk.samples.count {
                try Task.checkCancellation()
                let end = min(offset + perSlice, chunk.samples.count)
                let slice = Array(chunk.samples[offset..<end])
                guard let buffer = Self.makeBuffer(
                    samples: slice, sampleRate: chunk.sampleRate, target: analyzerFormat
                ) else { throw TranscribeError.conversionFailed }
                inputContinuation.yield(AnalyzerInput(buffer: buffer))
                offset = end
            }
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
