import Foundation

/// Who said it, as far as the audio can tell.
///
/// Not diarisation. The microphone and the system audio are transcribed as two
/// separate streams, so the only thing known is which stream a word came from:
/// the microphone is the person recording, the system audio is the other end
/// of the call. Two people on the far side are both "Them".
public enum Speaker: String, Sendable, Equatable, CaseIterable {
    case you = "You"
    case them = "Them"

    /// What begins a turn in the rendered transcript.
    public var label: String { "\(rawValue):" }
}

/// A stretch of speech the recognizer settled, with the time it covers.
///
/// Times are seconds. Straight out of a recognizer they are that recognizer's
/// own clock; after `SourceTimeline.place` they are the meeting's.
public struct TimedSegment: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// One speaker's uninterrupted run of segments.
public struct SpeakerTurn: Sendable, Equatable {
    public var speaker: Speaker
    public var start: TimeInterval
    public var text: String

    public init(speaker: Speaker, start: TimeInterval, text: String) {
        self.speaker = speaker
        self.start = start
        self.text = text
    }
}

/// Interleaves the two streams of a meeting into one labelled transcript.
///
/// **The rule for overlap:** segments are ordered by where they start, and a
/// segment is never split. When the other side talks over a long segment, the
/// interruption comes after the whole segment rather than inside it — the
/// recognizer's segment is the smallest unit whose words are known to be in
/// order, and cutting it at a guessed word boundary would invent a timing the
/// recognizer never reported. Equal starts put "You" first. Consecutive
/// segments from the same side become one turn.
///
/// **Labels only when both sides spoke.** A meeting where only one stream
/// produced text is rendered exactly as before this existed: segments joined
/// by spaces, no labels. An in-person meeting (nothing playing, so the tap
/// delivers nothing) hears everyone in the room through the microphone, and
/// "You:" in front of all of it would be wrong; a course at 2x has no
/// microphone at all.
public enum SpeakerTurns {
    /// Between turns. A blank line so a markdown reader — the vault — shows
    /// each turn as its own paragraph.
    public static let turnSeparator = "\n\n"

    public static func interleave(
        you: [TimedSegment], them: [TimedSegment]
    ) -> [SpeakerTurn] {
        // Tagged with the original index so equal starts keep their order:
        // `sort` is not guaranteed stable.
        let tagged = (you.enumerated().map { (Speaker.you, $0.offset, $0.element) }
                      + them.enumerated().map { (Speaker.them, $0.offset, $0.element) })
            .filter { !clean($0.2.text).isEmpty }
            .sorted { a, b in
                if a.2.start != b.2.start { return a.2.start < b.2.start }
                if a.0 != b.0 { return a.0 == .you }
                return a.1 < b.1
            }

        var turns: [SpeakerTurn] = []
        for (speaker, _, segment) in tagged {
            let text = clean(segment.text)
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].text = last.text + " " + text
            } else {
                turns.append(SpeakerTurn(speaker: speaker, start: segment.start, text: text))
            }
        }
        return turns
    }

    /// The transcript as the user, the summariser and the vault receive it.
    public static func render(you: [TimedSegment], them: [TimedSegment]) -> String {
        let turns = interleave(you: you, them: them)
        let speakers = Set(turns.map(\.speaker))
        guard speakers.count > 1 else {
            return turns.map(\.text).joined(separator: " ")
        }
        return turns
            .map { "\($0.speaker.label) \($0.text)" }
            .joined(separator: turnSeparator)
    }

    /// Whether a stored transcript carries speaker labels. Meetings recorded
    /// before labelling, and single-source ones, do not.
    public static func isLabelled(_ transcript: String) -> Bool {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        return Speaker.allCases.contains { trimmed.hasPrefix($0.label + " ") }
    }

    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Puts one recognizer's times on the meeting's clock.
///
/// Each stream has its own recognizer, and a recognizer's clock is the audio it
/// has been handed — not the wall. The microphone delivers continuously, so its
/// clock and the meeting's agree. System audio does not: an idle output device
/// delivers nothing at all (see `docs/traps.md`), so ten minutes of a paused
/// video are ten minutes the tap's recognizer never hears, and everything it
/// says afterwards would be dated ten minutes early — ahead of the microphone
/// it should come after.
///
/// So each read is stamped with the meeting time it ended at, and where a
/// stream's audio starts later than it would have if it had been continuous, an
/// anchor records the jump. No silence is fed to fill the gap: an hour of
/// zeros through a second recognizer is work for nothing. The anchors are one
/// per gap, not per read, so this stays a handful of pairs for a whole meeting.
///
/// A read's audio is taken to end at the moment it was read. That is true to
/// within the ring's capture latency, which both streams share.
public struct SourceTimeline: Sendable, Equatable {
    /// How far behind a stream may fall before it is treated as a gap rather
    /// than a drain's jitter. A read varies by up to a capture callback's worth
    /// of audio, which is well under this.
    public static let gapTolerance: TimeInterval = 0.5

    public let sampleRate: Double
    /// Samples handed to the recognizer so far.
    public private(set) var fed = 0
    /// Where recognizer sample `fed` sits on the meeting clock, in order.
    private var anchors: [Anchor] = []

    private struct Anchor: Sendable, Equatable {
        let fed: Int
        let at: TimeInterval
    }

    public init(sampleRate: Double = 16_000) {
        self.sampleRate = sampleRate
    }

    public var gaps: Int { max(0, anchors.count - 1) }

    /// Records `count` samples about to be handed to the recognizer, whose last
    /// sample was heard at meeting time `end`.
    public mutating func admit(_ count: Int, endingAt end: TimeInterval) {
        guard count > 0 else { return }
        let start = max(0, end - Double(count) / sampleRate)
        if anchors.isEmpty || start - meetingTime(ofSample: fed) > Self.gapTolerance {
            anchors.append(Anchor(fed: fed, at: start))
        }
        fed += count
    }

    /// Meeting time of a moment on the recognizer's clock.
    public func meetingTime(_ recognizerTime: TimeInterval) -> TimeInterval {
        meetingTime(ofSample: Int((recognizerTime * sampleRate).rounded()))
    }

    /// The same segments, re-timed onto the meeting clock.
    public func place(_ segments: [TimedSegment]) -> [TimedSegment] {
        segments.map {
            TimedSegment(start: meetingTime($0.start), end: meetingTime($0.end), text: $0.text)
        }
    }

    private func meetingTime(ofSample sample: Int) -> TimeInterval {
        // The last anchor at or before the sample. A handful of them per
        // meeting, so a scan from the end is the whole search.
        guard let anchor = anchors.last(where: { $0.fed <= sample }) ?? anchors.first else {
            return Double(sample) / sampleRate
        }
        return anchor.at + Double(sample - anchor.fed) / sampleRate
    }
}
