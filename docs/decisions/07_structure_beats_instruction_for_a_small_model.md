# Structure beats instruction on the on-device model

**Decided** 2026-08-23 · **Evidence** one recording, three violations

The summariser was told, in every prompt: never invent, leave garbled passages
out, do not explain a term you cannot make out, a short note is a good outcome.
Given a transcript where "Higgsfield and paste this URL" had come through as
"Shesfield and Pace this URL", it wrote a confident entry for a product called
**"Shesfield and Pace"**, defined **"emotion design"** as the craft of evoking
emotion, and listed both under **Worth looking up**.

Three prohibitions, three violations, in one pass.

The fix was structural: the "Worth looking up" and "Definitions" headings were
removed. A heading asking for names the speaker mentioned in passing is a
request to guess at exactly the words least likely to have survived
transcription, and a definition cannot be written without first deciding what
the term was.

**Generalisation:** on a model this size, remove the opportunity rather than
adding the instruction. Prohibitions are followed weakly; structure is followed.
