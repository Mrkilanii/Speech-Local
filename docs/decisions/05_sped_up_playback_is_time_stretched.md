# Sped-up playback is time-stretched, never resampled

**Decided** 2026-08-23 · **Evidence** same minute of the same video, both ways

Watching at 2× costs roughly **70%** of the transcript. Measured on one
passage: at 1× whole paragraphs return word-perfect — "the built-in assistant
literally takes you by the hand and guides you through the entire process" is
exact. At 2× the same passage is "I, I, I, I, I, I, and most importantly, find
find". Apple's recognizer is trained on speech at speaking pace and its
segmentation breaks first, which is why the wreckage is full of stutters.

A player speeding video up **preserves pitch**. Undoing it by resampling would
halve the pitch along with the rate and hand the recognizer a baritone it likes
even less. `AVAudioUnitTimePitch` stretches time alone, which is the inverse of
what the player did. `stretchingLeavesThePitchAlone` puts a 440 Hz tone through
at 2× and asserts it returns twice as long and still 440 Hz — that assertion is
the whole difference between the two approaches.

**Consequence:** above 1× the microphone is dropped. Only the playback was sped
up, so stretching a mix would slow the speaker's own voice to half pace.
