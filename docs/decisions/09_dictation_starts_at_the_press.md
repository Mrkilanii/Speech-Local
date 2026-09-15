# Dictation starts recording at the press, with no rewind

**Decided** 2026-09-15 · **Evidence** the user's report; the old value had none

The hotkey path used to rewind the capture cursor 0.4 s before the press. The
number was never measured. The design review only required that audio *exist*
around the press ("retain preroll audio continuously or accept/document clipped
onset"). That requirement is met by capture running from launch, not by
rewinding.

What 0.4 s did in practice was catch the end of whatever was said just before
pressing, which then showed up in the transcript.

The press is seen on key-down within milliseconds, since the gesture starts
recording optimistically before hold versus double-tap is resolved. So there was
no detection lag for the rewind to cover.

**Kept:** continuous capture from launch. Starting the engine on the press would
clip the opening syllable, and that is a different problem from rewinding.

**Not measured:** whether onsets are now clipped when speech starts at the same
instant as the press. If they are, add a small rewind based on a measurement
(order of 0.1 s), not the old 0.4 s.
