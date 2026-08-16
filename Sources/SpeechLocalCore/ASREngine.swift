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
    func transcribe(
        audio: AsyncStream<AudioChunk>,
        locale: String
    ) -> AsyncThrowingStream<String, Error>
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
