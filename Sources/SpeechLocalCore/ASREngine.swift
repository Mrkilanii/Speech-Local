import Foundation

public enum ASRUnavailable: Error, Sendable, Equatable {
    /// The locale is supported by the OS but its assets are not downloaded.
    case localeNotInstalled(String)
    /// The OS does not support this locale at all.
    case localeUnsupported(String)
    case microphoneDenied
    case other(String)
}

/// Turns captured audio into text.
///
/// Consumes a stream of buffers rather than one `[Float]`, so a long hands-free
/// session cannot grow without bound in memory.
public protocol ASREngine: Sendable {
    func availability(locale: String) async -> ASRAvailability

    /// Transcribes an audio stream, emitting cumulative text as it resolves.
    /// The final element is the complete transcript.
    ///
    /// `biasTerms` nudges the recognizer toward words the user has corrected
    /// before, exactly as the buffered path does — a meeting is the last place
    /// to give up on getting someone's name right.
    func transcribe(
        audio: AsyncStream<AudioChunk>,
        locale: String,
        biasTerms: [String]
    ) -> AsyncThrowingStream<String, Error>

    /// The same transcription, keeping when each segment was said.
    ///
    /// Emits every segment so far — settled ones, then the one still being
    /// guessed, if any — timed on the recognizer's own clock: seconds of audio
    /// it has been handed. The final element is the settled transcript. A
    /// meeting needs this to put two recognizers' output in order.
    func transcribeSegments(
        audio: AsyncStream<AudioChunk>,
        locale: String,
        biasTerms: [String]
    ) -> AsyncThrowingStream<[TimedSegment], Error>
}

extension ASREngine {
    /// For an engine that cannot say when anything was said: the whole
    /// transcript as one segment at the start. Enough for a single stream,
    /// where order within the stream is all there is.
    public func transcribeSegments(
        audio: AsyncStream<AudioChunk>,
        locale: String,
        biasTerms: [String]
    ) -> AsyncThrowingStream<[TimedSegment], Error> {
        let text = transcribe(audio: audio, locale: locale, biasTerms: biasTerms)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await partial in text {
                        continuation.yield([TimedSegment(start: 0, end: 0, text: partial)])
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum ASRAvailability: Sendable, Equatable {
    case available
    case unavailable(ASRUnavailable)
}

/// A slice of 16 kHz mono PCM lifted off the capture ring buffer.
///
/// Deliberately plain so the real-time audio thread never allocates or locks to
/// produce one.
public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double = 16_000) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}
