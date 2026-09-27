# Handoff

Read this first, then `AGENTS.md`. Newest state at the top; older entries stay.

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

**Omar's decisions:** build Wispr parity now, in parallel, not overnight (27 Sep).

**Open problems:** Wispr's implicit restatement ("I mean send it Wednesday") is
refused; `claude` CLI OAuth expired, so the agentic-coding-system harness can't
run until Omar logs in again; learning-from-edits rarely fires because Claude
desktop exposes no focused element (W6 spike not done).

**Next:** Omar runs the verification.md clipboard check; merge streaming ASR;
W6 Electron accessibility spike.
