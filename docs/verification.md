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
