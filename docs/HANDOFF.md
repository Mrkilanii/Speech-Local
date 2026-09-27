# Handoff

Read this first, then `AGENTS.md`. Newest state at the top; older entries stay.

## 2026-09-27 (night) — M8: meetings reach the wiki (built, not installed)

**Built on a worktree branch, not merged, not installed, and never run
against Claude** (decision 13):
- The app is unchanged and stays offline. `tools/ingest-meetings.sh` finds
  `raw/meetings/` files that are not yet ingested, oldest first, one per run.
  It runs `claude -p` in the vault with a prompt scoped to that one file and
  the vault's own ingest rules. It records the file in
  `~/Library/Application Support/SpeechLocal/ingested.txt` only after it has
  checked the vault: a source-summary names the file, the log names it, a
  commit exists, and nothing under `raw/` changed.
- Writes are limited to `wiki/` by permission rule, in `dontAsk` mode. The
  run refuses on a dirty vault, on a held lock, or with no since date.
- The launchd agent is `tools/dev.kilanii.speechlocal.ingest.plist`, every
  30 minutes. `make install-ingest` / `make uninstall-ingest` (refused
  from a worktree).
- `tools/test-ingest-meetings.sh`: 31 cases against a throwaway vault and a
  fake `claude`, all pass. The dry run against the real vault picks
  `2026-09-06-meeting-6-september-21-03.md` first under `--since 2026-09-01`.
  It sees the six hand-ingested meetings as done, through their
  source-summary `sources` (they are not named in `wiki/log.md`).

**Not verified:** any real `claude` session. That includes the permission
rules, launchd's access to `~/Documents` (TCC), and `git push` from launchd.
shellcheck is not installed, so it was not run.

**Omar's move:** log in with `claude`, merge, then from the main checkout run
`make install-ingest` and `launchctl kickstart gui/$(id -u)/dev.kilanii.speechlocal.ingest`,
and check it against verification.md, "Meetings reach the wiki". The backlog
from before the install is four meetings: 31 Aug, 6 Sep ×2, 7 Sep.
`--since all --max 5` takes it deliberately.

## 2026-09-27 (evening) — parallel stages landed

- **Streaming ASR merged** (33a2e37); **W6 Electron accessibility** (c0d2311).
- **M7 speaker labels** merged: mic and system audio transcribed separately,
  interleaved as You/Them (decision 12). Not run on a live call; echo on
  laptop speakers is not handled — count duplicates on a speakers call.
- **Code key writes Python / Pseudocode / SQL / TypeScript**, chosen in
  Settings or the menu bar. SQL uses Cambridge naming (Trace Table's tables).
  None of the three new languages has been dictated live.
- **Build Order** replaces docs/build-order.md: JSON in docs/build-order/,
  rendered by tools/render_build_order.py, published at
  https://claude.ai/artifact/7zpeck57CfHsYrZQX4CxCF. Republish after every reply.
- Known small bug: an open Settings window keeps its own copy of settings, so
  changing the code language from the menu and then editing Settings reverts it.

## 2026-09-27 — M7: meeting transcripts labelled "You" / "Them"

**Built on branch `worktree-agent-ac6da6e32cf36c5cf`, not merged, not run
live** (decision 12):
- Mic and system audio are no longer mixed. Each has its own streaming
  recognizer (`MeetingSession`); the system one starts on the tap's first
  buffer. `ASREngine.transcribeSegments` reports timed segments;
  `SourceTimeline` puts both on the meeting clock across tap silences;
  `SpeakerTurns` interleaves by start into `You:` / `Them:` turns.
- One side only (in-person, or 2×) renders unlabelled, exactly as before.
- Summariser prompts say who "You" and "Them" are. Worst-case labelled window
  measured at 2,909 tokens with `tokenCount`; map call ≈ 3,440 of 4,096.
- Vault file carries the labels plus a one-line legend.
- 463 tests green; `swift build -c release` clean.

**Not verified:** any live call; echo on speakers (the other side can appear
twice); CPU/memory of two recognizers; the incremental reader's word offset
when a late segment lands before it. The acceptance test is
`docs/verification.md` → "Meetings: You and Them".

**Next:** merge, `make all`, Omar runs that test with headphones, then once on
speakers to count echoes.

## 2026-09-27 — dictation: clipboard, password guard, Wispr-style corrections

**Live (HEAD, app rebuilt and running):**
- Paste restores the user's clipboard only on evidence the paste was read
  (`PasteRestore`, `TextInserter.insertViaPaste`). No evidence in 2 s → the
  transcript stays; menu "Restore previous clipboard". Every decision is logged
  as `PASTE …` in doctor.log.
- `InsertionGuard`: nothing is inserted into SecurityAgent/loginwindow, a secure
  field, or under secure input. At release, SecurityAgent audio is discarded
  before recognition.
- Backtrack (decision 11): `DiscourseFillers`, `ScratchThat`, `CorrectedValue`,
  composed in `Backtrack`, English, not code mode, Settings switch.
- `ChatPunctuation`: trailing period dropped in Messages/WhatsApp/Discord.
- Every dictation padded with 0.5 s silence; recording continues 150 ms after
  release (short dictations were returning empty — measured, see decision 11 /
  verification.md).
- History records the text actually typed, after insertion.

**Not verified live:** all of the above except the lazy-clipboard mechanism
(proved with pbpaste). Omar has not dictated on this build yet. The
`docs/verification.md` clipboard check is the acceptance test.

**Streaming ASR merged (later on 27 Sep):** the recognizer is fed while the
key is held; release only finalises. `SpeechLocalStdin --realtime` measures it
without a microphone: 37–54 ms after release for short phrases, 150–600 ms for
23–46 s clips under load. Falls back to the buffered path on error or empty.
Live figure: `STREAM final +N ms after release` in doctor.log.

**W6 done (27 Sep):** `TextInserter.wakeAccessibility` sets
`AXManualAccessibility` on the frontmost app at the key press. `--probe-electron`
measured Claude desktop going from 9 nodes / no focus to 713 nodes with a
readable, settable `AXTextArea`; no measurable CPU rise. ChatGPT refuses it
(-25205); Arc and Chrome exposed nothing to the probe (not investigated).

**Omar's decisions:** build Wispr parity now, in parallel, not overnight (27 Sep).

**Open problems:** Wispr's implicit restatement ("I mean send it Wednesday") is
refused; `claude` CLI OAuth expired, so the agentic-coding-system harness can't
run until Omar logs in again; learning-from-edits rarely fires because Claude
desktop exposed no focused element — addressed by W6 above, not yet seen live.

**Next:** Omar runs the verification.md clipboard check; merge streaming ASR;
W6 Electron accessibility spike.
