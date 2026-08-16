# FlowLocal

Hold a key, speak, and finished text appears where your cursor is — in any app.
Entirely on-device. No account, no subscription, no network at runtime.

A local alternative to [Wispr Flow](https://wisprflow.ai), which does the same
job but sends your audio to the cloud and charges monthly.

> **Status: working, early.** The core loop runs end to end. Settings UI,
> launch-at-login, and a packaged release are not built yet. See
> [Limitations](#limitations) — they are specific and worth reading before you
> decide this is for you.

---

## What it does

| Gesture | Result |
|---|---|
| **Hold Right Option**, speak, release | Light-touch cleanup, inserted at your cursor |
| **Hold Right Command**, speak, release | Full rewrite into structured prose |
| **Double-tap** either key | Hands-free — speak, then tap once to stop |

A small capsule sits at the bottom of your screen showing a live waveform while
recording, with **✕** to discard and **✓** to stop early. When no text field is
focused, it expands to show the text with a Copy button rather than throwing it
away.

**Light-touch** fixes punctuation, capitalization, and removes filler words. It
changes nothing else — your hedges, your phrasing, your "you know"s all survive.
**Full rewrite** restructures rambling speech into clean prose.

### It learns how you speak

When a word comes out wrong, open **Fix last dictation…** from the menu bar and
correct it. FlowLocal remembers, and:

- feeds the word to the recognizer as a bias hint, so it is more likely to be
  heard correctly next time;
- after you have confirmed the same correction twice, repairs it directly — but
  **only in the surrounding context you corrected it in**. Teaching it that
  "tip" meant "ship" in *"we should tip it"* will never break *"leave a tip for
  the driver"*.

This is a correction layer, not model training. Apple's speech model cannot be
fine-tuned on-device. The practical effect is the same — the same mistake stops
surviving — but it will not generalise to words you have never corrected.

---

## Requirements

- **macOS 26 (Tahoe) or later** — needs `SpeechTranscriber` and `FoundationModels`
- **Apple Silicon**
- **Command Line Tools** — full Xcode is *not* required
- **Apple Intelligence enabled** for full-rewrite mode only. Light-touch and
  transcription work without it.

No model downloads. `en-US` speech assets ship with macOS.

---

## Install

See **[BUILDING.md](BUILDING.md)**. It is short, but the certificate step is not
optional — skipping it means macOS silently revokes your permissions on every
rebuild.

---

## How it works

```
Right Option ──► CGEventTap ──► gesture state machine
                                        │
   microphone ──► ring buffer ──────────┤   (always recording, 30 s of history)
                                        ▼
                              SpeechTranscriber (on-device)
                                        │
                              learned corrections
                                        │
                    ┌───────────────────┴───────────────────┐
              light-touch                              full rewrite
            RulesCleanup (0.3 ms)                FoundationModels (~7 s)
                    └───────────────────┬───────────────────┘
                                        ▼
                          Accessibility API ─or─ synthesized ⌘V
```

Two design decisions are worth explaining, because both were reversed by
measurement rather than chosen up front.

**Light-touch does not use the LLM.** It was supposed to. On this hardware
`FoundationModels` ran a median of **7.2 s** for novel input — 0 of 10 test
utterances landed inside the 1.5 s budget — and in 2 of 10 it silently truncated
or emptied the output *with no error raised*. For a mode whose entire contract is
"fix punctuation, change nothing else", losing your words is a correctness
failure. Deterministic rules run in **0.3 ms** and structurally cannot drop
content. The LLM is retained for full rewrite, where rewording is the point and
waiting is acceptable, behind a guard that rejects empty or truncated output.

**Audio records continuously, not from the keypress.** The first key-down is
ambiguous — it could begin a hold, or be the first half of a double-tap — and
cannot be classified until the gesture resolves. Recording from the press would
clip the start of every utterance, so a ring buffer always holds the last 30
seconds and the app rewinds into it.

---

## Limitations

Known and deliberate, not bugs to report:

- **Self-corrections are not resolved.** Say *"Monday, no actually Tuesday"* and
  you get both. Apple's model would not do this either, even given an explicit
  rule and a worked example in the prompt.
- **Commas follow a heuristic, not a grammar.** A comma survives before a clause
  marker (`and`, `but`, `because`, …) or inside a list. Appositives ("my friend,
  Omar, called") and introductory phrases lose theirs. Scattering commas through
  your sentences was judged the worse failure.
- **A capital after a real full stop is left alone**, even if the full stop came
  from you pausing. A genuine sentence break is indistinguishable from a
  pause-induced one, and deleting a real boundary is worse than keeping a stray
  capital.
- **Stutters on real words need teaching.** "st stop" is collapsed
  automatically; "to today" is not, because "go **to today's** meeting" is
  identical in shape. Correct it once and it is learned in context.
- **English only.** Other locales are supported by the OS but untested here.
- **No settings UI yet.** Hotkeys and vocabulary are code constants.

---

## Privacy

Nothing leaves your machine at runtime. Transcription and cleanup both run
on-device through Apple frameworks with no server path. Learned corrections live
in `~/Library/Application Support/FlowLocal/corrections.json` and are never
transmitted. There is no analytics, no account, and no update check.

The app deliberately refuses to type into password fields, identified by
accessibility subrole.

---

## Credits

Built on Apple's `SpeechAnalyzer`, `SpeechTranscriber`, and `FoundationModels`.

[VoiceInk](https://github.com/Beingpax/VoiceInk) is the best open-source app in
this space and was read for technique. It is GPL-3.0; **no code was taken from
it** — FlowLocal is MIT and everything here is written against Apple's
documentation.

## License

MIT — see [LICENSE](LICENSE).
