# Speakers are the two audio streams, each with its own recognizer

**Decided** 2026-09-27 · **Evidence** `SpeakerTurnsTests`, `MeetingSessionTests`,
token counts below · **Replaces** the mic-plus-system mix from stage 10

The meeting used to sum the microphone and the system audio into one stream
before recognition, so who said what was gone before a word was recognised.
Now each stream has its own streaming recognizer, and the transcript is their
finalized segments interleaved by time:

```
You: Can we ship Friday?

Them: Yes, if QA signs off.
```

**"You" is the microphone; "Them" is the system audio.** That is all the audio
can tell. It is not diarisation: three people on the far end are all "Them",
and anyone in the room with the user is "You".

## The rules

- **Order by start; never split a segment.** A segment that overlaps the other
  side's stays whole and goes where it starts. The recognizer does not say
  which word fell at which second, so splitting would invent a timing. Equal
  starts put "You" first. Consecutive segments from one side are one turn.
- **Labels only when both sides said something.** One side alone renders
  exactly as before: segments joined by spaces, unlabelled. An in-person
  meeting (nothing plays, so the tap delivers nothing) is the microphone
  hearing the whole room; a course at 2× has no microphone at all.
- **The system recognizer starts on the tap's first buffer.** A tap that never
  delivers costs no second recognizer.
- **One clock.** A recognizer's clock is the audio it was handed, and the tap
  hands nothing while nothing plays (`traps.md`). `SourceTimeline` stamps each
  read with the meeting time and anchors a jump when a stream falls more than
  0.5 s behind, so a video paused for ten minutes does not date everything
  after it ten minutes early. No silence is fed to fill gaps.
- **No audio kept.** Each drain goes to its recognizer and is let go, as
  before (decision 04). What grows is the segment list — text plus two doubles
  each.

## Rejected

- **Keep the mix and diarise it.** Nothing on-device in Apple's frameworks
  separates voices, and a diarisation model is a download and a model-management
  subsystem this app exists without. The two streams already *are* the
  separation that matters for a call.
- **Fill a silent stream with zeros** to keep both recognizers on one clock.
  Simpler maths, but an in-person hour would push an hour of silence through a
  second recognizer. Anchoring costs one pair of numbers per gap.
- **Split an overlapped segment at the interruption.** Needs per-word times,
  which the transcriber can report (`audioTimeRange`) but is not asked for.
  Worth it only if the live test shows long segments hiding interruptions.

## Prompt budget (decision 08)

Measured with `SystemLanguageModel.tokenCount` on macOS 26.6, which also
reports `contextSize` = 4,096 — the limit decision 08 found by overflowing it
is now read from the API.

| | tokens |
|---|---|
| Map prompt, with the "You"/"Them" paragraph (265 words) | 369 |
| 1,826 words of prose, unlabelled | 2,475 |
| Same, a label every sentence (85 turns), joined as the chunker joins | 2,645 |
| 1,800-word window, a label every 8 words (225 turns) — worst case | 2,909 |

Worst case map call: 2,909 + 369 + ≤160 answer ≈ 3,440, under 4,096. The
chunker counts a label as a word, so labels come out of the 1,800-word window
rather than on top of it. `aLabelledWindowStillFitsTheContext` holds the
arithmetic.

## Not measured

- **A real call.** Nothing here has run against live audio. The unit tests use
  a stub recognizer with exact timings.
- **Echo.** On speakers rather than headphones, the microphone also hears the
  other side, so their words can appear twice — once as "Them", once as "You".
  The mix hid this by summing both into one recognizer. No echo suppression is
  built; measure first.
- **Two recognizers at once.** CPU and memory with two `SpeechAnalyzer`s
  running for an hour; `--probe-meeting` measures the memory half.
- **Incremental reading.** The summariser reads the transcript by word offset
  while it records. A segment that settles late and is placed before words
  already read shifts the offset by its length, so a window may re-read or skip
  a sentence at its edge. The filed transcript is unaffected.
