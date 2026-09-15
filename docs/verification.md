# Verifying it actually works

The unit suite covers pure logic and cannot see audio, permissions, the model,
or the UI. Everything below needs the built app. Several real bugs here were
invisible to a green suite.

## The suite

```bash
make test        # 327 tests, ~1.5s, no signing needed
```

Covers text pipelines end to end: cleanup, numbers, punctuation, learned
corrections, chunking, the meeting session against a stub recognizer, the vault
writer against a temporary directory.

## The probes

Each is a flag on the bundle. Run them the way `traps.md` says, and read
`~/Library/Logs/SpeechLocal/doctor.log`.

| Flag | Proves |
|---|---|
| `--diagnostics` | Permissions, model availability, locale assets, the light-touch corpus |
| `--probe-audio-sources` | CoreAudio tap vs ScreenCaptureKit, with rms per path. Needs audio playing |
| `--probe-meeting <seconds>` | Memory slope over a long session, and a level and buffer count per source |
| `--ab` | Cleanup prompt comparison |

`--probe-meeting` refuses to judge a memory trend under two minutes: two
samples sixteen seconds apart once extrapolated a 1.4 MB wobble into
"+330 MB/hour" and called it a leak. Use 300 or more.

## What a good result looks like

**Memory, both sources live, five minutes:** `+1.7 MB/hour`, resident steady
around 30–34 MB, `audio lost to overrun: false`. The dictation path holds
230 MB/hour by comparison, which is why it is capped at five minutes.

**System audio:** a level above zero *and* a rising buffer count. Either alone
is misleading — see `traps.md`.

**Dictation:** the log's `ASR` and `CLEAN` lines for one utterance. Compare
them; the difference is exactly what the cleanup pipeline did.

## What no probe covers

Summary quality. There is no test for whether a note is worth reading, and the
model's failures are fluent rather than obvious — it invented a person, a
company and a definition from one garbled transcript while following every
instruction it was given about not inventing. Read the output against a source
you know.

## Code dictation: the C3 script

Proves the library-name path against a real voice. `PythonScriptC3Tests`
already shows the rules produce this code when every word is heard, so every
difference in a live run is the recognizer's, and each one is a candidate for
the confusion tables.

1. Open an empty Python editor (Trace Table's Editor tab, or a `.py` file in
   VS Code). Hold the code key once per press below; wait for each to land.
2. Copy the result and diff it against the expected code in the test.
3. Read the `ASR` lines in `doctor.log` for every line that differs.

| Press | Say |
|---|---|
| 1 | import pandas as p d · next line · import numpy as n p · next line · import matplotlib dot pyplot as p l t |
| 2 | d f equals p d dot read csv quote sales dot csv · next line · d f equals d f dot drop n a · next line · print d f dot head · next line · print d f dot shape |
| 3 | total equals d f open square quote price close quote close square dot sum · next line · average equals n p dot mean d f open square quote price close quote close square · next line · print f string capital average price colon curly average close curly |
| 4 | by region equals d f dot group by quote region close quote close open square quote price close quote close square dot mean · next line · by region dot plot kind equals quote bar · next line · p l t dot title quote capital average price by region · next line · p l t dot x label quote capital region · next line · p l t dot show |
| 5 | high equals d f open square d f open square quote price close quote close square greater than 100 close square · next line · print len high · next line · for region in d f open square quote region close quote close square dot unique colon · next line · print region |
| 6 | (on a new, unindented line) def summarise taking data colon · next line · return data dot describe · next line · dedent print summarise open paren d f |
