# Build order

**Reads:** `git log`, `docs/decisions/`.
**Does:** shows the order the app was built in, and the order proposed from here.
**Writes:** a new future stage when one is agreed; a past stage when one lands.
**Human checks:** that each "verified" claim names a real run.

Past stages are history and keyed to commits, so they do not drift. Future
stages are a proposal. **The commit log is still the status** (`CONTEXT.md`):
if this file and `git log` disagree, `git log` wins.

---

## Done

| # | Stage | Dates | Commits | Proven by |
|---|---|---|---|---|
| 1 | **Foundation.** Signed bundle, permissions, spikes. The model was rejected for light-touch (7.2 s median, dropped words on 2 of 10) | 16 Aug | `0a28474` | Spikes, decision 01 |
| 2 | **Dictation core.** Hotkey, continuous mic, SpeechAnalyzer, insertion, the pill, sounds | 16 Aug | `cc9ca42`…`32bd321` | Live use |
| 3 | **Product shell.** Settings, vocabulary, launch at login, regression corpus, diagnostics, docs | 16 Aug | `22ba8c4`…`b05ddaf` | Corpus plus `--diagnostics` |
| 4 | **Hardening from live use.** Rewrite stops answering the user; no-target detection; long-dictation truncation; sleep; apps with no AX; clipped ends | 16 Aug | `3247734`…`c5c16e4` | Live use |
| 5 | **Languages and history.** Transcript history, 54 locales (two transcribers), Arabic, revoked-AX detection | 17 Aug | `552b06d`…`ecc2d61` | Live use |
| 6 | **Open-source release.** README, identifiers removed, renamed to SpeechLocal, opens on double-click | 17 Aug | `dbd7242`…`efe409d` | Fresh install |
| 7 | **Transcript accuracy.** Analyzer fed in slices; only finalized results kept | 17 Aug | `4958c9d`, `ac2b801` | Live use |
| 8 | **Spoken formatting.** Digits, separators, spoken punctuation, comma policy, lists, brackets | 17 Aug | `29fd956`…`a7e7368` | Unit tests plus live use |
| 9 | **Learning.** Learns from in-app edits, lowercase mid-sentence, a taught name kept out of words that sound like it | 17–22 Aug | `606bbbc`, `426dc07`, `4929c03`, `9b12f80` | Unit tests plus live use |
| 10 | **Meeting capture.** Headless transcriber, system-audio spike, a session holding no audio, mic mixed with system audio | 19–22 Aug | `07a5bfd`, `2ce7d64`, `7344eb3`, `4c00ac3` | `--probe-meeting`: +1.7 MB/hour (decision 04) |
| 11 | **Meeting notes.** Summariser, window, store, vault filing, talk/conversation kinds, 2× time-stretch, vocabulary, menu state, privacy | 22–23 Aug | `42e666b`…`5a546c6` | End-to-end recording; vault file checked (decisions 02, 03, 05, 06, 07) |
| 12 | **Repo structure.** `CLAUDE.md` router, `docs/`, traps, decisions | 30 Aug | `f3ed8b5` | Nothing to run |
| 13 | **Long meetings.** Pause, hierarchical fold, re-summarise, reading while recording, note length bounded in code | 31 Aug – 15 Sep | `6e3700d`…`df363f7` | Fold and fallback seen live; **reading while recording and `fitToBudget` are unit tests only** (decision 08) |
| 14 | **Onset and updating.** Dictation starts at the press; README section on updating | 15 Sep | `2b03961`, `f1d38ea` | **Onset clipping not measured** (decision 09) |
| 15 | **Python dictation.** Spike (recognizer output, bias, padding, custom LM); grammar; third hotkey; name table from 7 libraries | 15 Sep | this commit | 364 tests; spike table in decision 10. **Not yet dictated live by a person** |

---

## Proposed next

The order within each track is ordered by what could sink it, riskiest first. That order is not a matter of taste. Track V can run
alongside the others, because it costs recording time, not build time.

### V — Verification debts (alongside the others)

| # | Stage | Done when |
|---|---|---|
| V1 | Record one meeting of 60+ minutes on the current build | The log shows incremental windows read, fold report, and the note's length within budget |
| V2 | Measure onset clipping at 0 s preroll | 20 dictations starting on a plosive; count first-word losses |
| V3 | Launch at login survives `make all` | Rebuild, reboot, app running |

### C — Code dictation, Python first

| # | Stage | Done when |
|---|---|---|
| C0 | **Spike, before any grammar.** (a) What the recognizer writes for ~30 dictated Python lines. (b) What insertion does in VS Code, the Terminal REPL and Jupyter | (a) **done, stage 15** (decision 10). (b) **not done**: one press is one line and the editor indents, so (b) folds into C2's live check |
| C1 | **Python grammar in `SpeechLocalCore`.** Recognizer casing and punctuation stripped outside strings; operators; keywords; strings to end of line; brackets closed at the end; block colons; identifiers joined | **Done, stage 15**: `PythonDictationTests`, 21 cases taken from real recognizer output |
| C2 | **Wiring.** Third hotkey (right Option for Omar, Right Control by default); one press is one line; 0.5 s silence padding | **Built, stage 15.** Done when a 15-line script is dictated into VS Code and runs unedited |
| C3 | **Library names.** 5,965 names generated from the libraries (`scripts/python_names.py`), with owner-scoped fuzzy matching | **Built, stage 15.** Bias terms dropped: no measured effect. Done when a fixed 30-line data script dictated by a person is scored |
| C4 | **Cambridge pseudocode.** The same engine with a different table: upper-case keywords, `←`, `ENDIF`, `OUTPUT`/`INPUT` | Corpus plus a live script |
| C5 | **SQL** | Corpus plus live |
| C6 | **TypeScript.** Braces, semicolons, camelCase: the identifier join rule changes | Corpus plus live |
| C7 | *Optional:* the model on the rewrite key, for "write a function that…" | Only if a spike beats decision 01's numbers for code |

### M — Meetings, continued

| # | Stage | Done when |
|---|---|---|
| M7 | Speaker labels: mic versus system audio as "you" and "them" at minimum | A two-sided call labelled correctly |
| M8 | Close the vault loop: a filed meeting triggers or queues `ingest` | A meeting reaches `wiki/` without a manual step |
| D1 | Dictation on the streaming ASR path, removing the 5-minute cap | A 10-minute dictation with flat memory |

### Open problems (no stage yet)

- **Proper nouns.** Bias terms do not compel the recognizer: "Higgsfield",
  "numpy" → "non-pi", "matplotlib" → "math plot lip" (all from the log). C3
  attacks this for code only.
