# FlowLocal

Hold a key, speak, and finished text appears where your cursor is — in any app.
Entirely on-device. No account, no subscription, no network at runtime.

A local alternative to [Wispr Flow](https://wisprflow.ai), which does the same
job but sends your audio to the cloud and charges monthly.

---

## What it does

| Gesture | Result |
|---|---|
| **Hold Right Option**, speak, release | Light-touch cleanup, inserted at your cursor |
| **Hold Right Command**, speak, release | Full rewrite into structured prose |
| **Double-tap** either key | Hands-free — speak, then tap once to stop |

A small capsule sits at the bottom of the screen with a live waveform while
recording, **✕** to discard and **✓** to stop early. When there is nowhere to
type, it shows the text with a Copy button and a 10-second countdown instead of
throwing it away.

**Light-touch** fixes punctuation, capitalisation, filler words, stutters,
restated sentences and contractions. It changes nothing else — your hedges and
phrasing survive. **Full rewrite** restructures rambling speech into clean prose.

### It learns how you speak

When a word comes out wrong, open **Fix last dictation…** from the menu bar and
correct it. FlowLocal then:

- feeds the word to the recognizer as a bias hint, so it is more likely to be
  heard correctly next time;
- after the same correction twice, repairs it directly — but **only in the
  context you corrected it in**. Teaching it that "tip" meant "ship" in *"we
  should tip it"* will never break *"leave a tip for the driver"*.

This is a correction layer, not model training: Apple's speech model cannot be
fine-tuned on-device. The effect is the same — the same mistake stops surviving —
but it will not generalise to words you have never corrected.

---

## Requirements

- **macOS 26 (Tahoe) or later**, Apple Silicon
- **Command Line Tools** — full Xcode is *not* required
- **Apple Intelligence** enabled, for full-rewrite mode only. Light-touch and
  transcription work without it.

English speech assets ship with macOS; nothing else needs downloading to start.

---

## Installation

Four steps. **Step 2 is not optional** — skip it and macOS silently revokes your
permissions on every rebuild, leaving an app that launches fine and does nothing.

### 1. Get the code and check the toolchain

```bash
xcode-select --install          # skip if already installed
git clone https://github.com/<you>/flowlocal.git
cd flowlocal
make test
```

You should see `176 tests ... passed`.

> **Do not put the repo in iCloud Drive** — that means `~/Documents` or
> `~/Desktop` if "Desktop & Documents" syncing is on. `fileproviderd` re-adds
> `com.apple.FinderInfo` to the app bundle faster than the build can strip it,
> and `codesign --verify --strict` then fails permanently with *"resource fork,
> Finder information, or similar detritus not allowed"*. It also syncs your
> `.build` directory on every compile. `~/Developer` is a good home.

### 2. Create a signing certificate

```bash
make cert
```

This creates a self-signed code-signing identity called `FlowLocal Dev` in your
login keychain.

**Why it matters.** macOS ties permission grants to an app's code signature.
Ad-hoc signing mints a *new* identity every build, so each rebuild looks like a
brand-new app: your Accessibility grant is dropped and macOS stops prompting for
it. The app then runs, sees no permissions, and does nothing. A stable identity
fixes this permanently.

> `security find-identity -v -p codesigning` will report **zero** identities even
> after this succeeds. Expected: `-v` filters to *trusted* certificates and a
> self-signed root is untrusted. Trust governs signature *verification*, not
> signing. Do not add trust — it triggers an admin prompt and buys nothing.

### 3. Build, sign, and grant permissions

```bash
make sign
open dist/FlowLocal.app --args --request-permissions
```

Approve both prompts — **Accessibility** and **Microphone**. If FlowLocal is not
listed under Accessibility, add `dist/FlowLocal.app` manually in System Settings
→ Privacy & Security → Accessibility.

> **Launch from Finder, not the terminal.** A permission grant attaches to the
> *responsible* process, so running the binary from a shell gives the grant to
> Terminal — and `AXIsProcessTrusted()` will then return `true` because it
> inherited Terminal's. Always test through the bundle.

Verify:

```bash
make doctor      # prints ALL CHECKS PASS
```

### 4. Run it

```bash
open dist/FlowLocal.app --args --listen
```

A small capsule appears at the bottom of the screen and a microphone icon in the
menu bar. Hold **Right Option** and speak.

To have it start automatically: **Settings → General → Launch at login**.

---

## Settings

Menu bar icon → **Settings…**

- **General** — hotkey bindings, dictation language, punctuation policy, sounds,
  transcript history, launch at login
- **Vocabulary** — names and jargon the recognizer gets wrong
- **Learned** — corrections picked up from *Fix last dictation…*, with their
  evidence count; delete any that misfire
- **History** — your last 200 dictations, searchable

### Languages

**54 are supported.** The picker lists only those downloaded; use **Download
language** to add one, and it is selected automatically when it arrives.

Apple ships two transcription engines with different coverage, and FlowLocal
picks per language:

| Engine | Languages |
|---|---|
| `SpeechTranscriber` | English, German, Spanish, French, Italian, Japanese, Korean, Portuguese, Chinese, Cantonese |
| `DictationTranscriber` | Arabic, Hebrew, Hindi, Polish, Turkish, Thai, Vietnamese, Russian, Ukrainian, Nordic and others |

**Cleanup rules exist for English and Arabic only.** Every other language is
transcribed and punctuated by the recognizer and then left alone — deliberately,
because running English filler lists and contraction tables over French or
Japanese would mangle them. Adding a language properly means a filler set, clause
markers and punctuation rules; contributions welcome.

### Transcript history

Off in one click, on by default, and worth understanding before you leave it on:
it records **everything you dictate**, which for a dictation app can include
passwords read aloud and private messages.

- Capped at **200 entries** — never an unbounded archive of your speech
- **Turning it off deletes what was already stored**, not merely hides it
- Written `0600` under `~/Library/Application Support/FlowLocal/`
- Never transmitted; excluded from version control

---

## How it works

```
Right Option ──► CGEventTap ──► gesture state machine
                                        │
   microphone ──► ring buffer ──────────┤   (always recording, drained each second)
                                        ▼
                      SpeechTranscriber / DictationTranscriber
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

Three decisions are worth explaining, because measurement reversed all of them.

**Light-touch does not use the LLM.** It was supposed to. On this hardware
`FoundationModels` ran a median of **7.2 s** for novel input — 0 of 10 test
utterances inside the 1.5 s budget — and in 2 of 10 it silently truncated or
emptied the output *with no error raised*. For a mode whose contract is "fix
punctuation, change nothing else", losing your words is a correctness failure.
Deterministic rules run in **0.3 ms** and structurally cannot drop content. The
LLM is kept for full rewrite, behind a guard that rejects empty or truncated
output.

**Audio records continuously and is drained every second.** The first key-down is
ambiguous — hold, or first half of a double-tap? — and cannot be classified until
the gesture resolves, so a ring buffer always holds the recent past. But the ring
is a 30-second window, not storage: a 32.77 s paragraph once lapped it and ate
its own opening, so audio is now moved out of it continuously.

**Insertion checks what the target can actually do.** An app with no
accessibility state at all (terminals, Codex) is pasted into blind. An element
that reports itself non-editable — you clicked *off* the text box — gets the Copy
panel. An editable element is written to directly.

---

## Limitations

Known and deliberate, not bugs to report:

- **Self-corrections are not resolved.** Say *"Monday, no actually Tuesday"* and
  you get both. Apple's model would not do this either, even given an explicit
  rule and a worked example.
- **`its` vs `it's`** is untouched. Only grammar distinguishes them, which rules
  cannot do.
- **Fused stutters** survive. When the recognizer merges a restart into one token
  ("thingsings"), nothing token-level can see inside it.
- **Commas follow a heuristic, not a grammar.** One survives before a clause
  marker or inside a list. Appositives ("my friend, Omar, called") lose theirs.
- **A capital after a real full stop is left alone**, even if you only paused. A
  genuine sentence break is indistinguishable from a pause-induced one, and
  deleting a real boundary is worse than keeping a stray capital.
- **In apps with no accessibility state**, clicking off the input still pastes
  into it — there is no state exposed to tell the two apart.

---

## Privacy

Nothing leaves your machine at runtime. Transcription and cleanup both run
on-device through Apple frameworks with no server path. Learned corrections and
history live under `~/Library/Application Support/FlowLocal/` and are never
transmitted. No analytics, no account, no update check. The only network access
is downloading a language you explicitly asked for.

The app refuses to type into password fields, identified by accessibility
subrole.

---

## Troubleshooting

**Hotkeys stop working.** Check Accessibility is still granted. FlowLocal
notices revocation within two seconds and says so in the menu bar; re-granting
rebuilds the event tap without a restart.

**Nothing is inserted, text appears in the Copy panel instead.** The focused
element reported itself non-editable. Click into the text field and retry.

**`make doctor` fails on microphone.** The hardened runtime denies microphone
access *silently* without `com.apple.security.device.audio-input` — no prompt
appears and the status stays `notDetermined`. Confirm `build/FlowLocal.entitlements`
is present and re-run `make sign`.

**Logs** are at `~/Library/Logs/FlowLocal/doctor.log`, and record the focused
app, its AX role, timings, and which insertion path was used.

---

## Development

| Target | Does |
|---|---|
| `make test` | Swift Testing suite (176 tests) |
| `make cert` | One-time self-signed identity |
| `make sign` | Build, assemble the bundle, sign, verify |
| `make doctor` | Diagnostics inside the signed bundle |
| `make clean` | Remove `.build` and `dist` |

See [BUILDING.md](BUILDING.md) for toolchain notes that cost real time to
discover — XCTest being absent from Command Line Tools, AMFI rejecting comments
in entitlements, and why benchmarks are fiction unless machine load is checked.

## Credits

Built on Apple's `SpeechAnalyzer`, `SpeechTranscriber`, `DictationTranscriber`
and `FoundationModels`.

[VoiceInk](https://github.com/Beingpax/VoiceInk) is the best open-source app in
this space and was read for technique. It is GPL-3.0; **no code was taken from
it** — FlowLocal is MIT and everything here is written against Apple's
documentation.

## License

MIT — see [LICENSE](LICENSE).
