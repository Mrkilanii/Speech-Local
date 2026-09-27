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

## Insertion: the clipboard is never pasted instead of the dictation

Every paste now logs its evidence: `PASTE restore +NNN ms reads [+x,+y] ax
true|false in <app>`, `PASTE keep (no evidence of a read)`, or `PASTE abandon`.

1. Copy a sentinel (`SENTINEL-42`) to the clipboard.
2. Dictate 20 times each into Claude, ChatGPT, Arc, Chrome and Terminal.
3. **Pass:** every insertion is the dictation, never `SENTINEL-42`; after each
   `PASTE restore`, `pbpaste` prints `SENTINEL-42`; after `PASTE keep`, the
   menu's Restore previous clipboard brings it back.
4. Copy something new within half a second of a paste: the log says
   `abandon`, and your new copy is still on the clipboard.

Measured before building (27 Sep): a lazy clipboard item written by one
process and pasted by another served the text and recorded the read at
+369 ms — the read time the old 120 ms restore lost to.

## Meetings: "You" and "Them" (decision 12)

Needs a real call — a friend on FaceTime, Zoom or Meet — **with headphones**,
so the microphone does not also hear the other side.

1. Record 5 minutes at 1×, kind Conversation. Take turns: you ask, they answer,
   at least 10 exchanges. Once, talk over them for a few seconds. Once, both
   stay silent for 20 seconds.
2. **Pass:** the transcript alternates `You:` / `Them:` in the order the
   exchanges happened; each of your questions is under `You`, each answer
   under `Them`; no exchange appears out of order by more than one turn; the
   talk-over appears whole, directly after the turn it interrupted.
3. The log's `MEETING stopped` line shows `system audio` seconds close to the
   call's length and `labelled: true`. The note keeps "You" for what you
   committed to — never a guessed name.
4. File it: the vault file carries the labels, one turn per paragraph, with the
   one-line legend under `## Transcript`.
5. Record 2 minutes with nothing playing (just you talking). **Pass:** the
   transcript has no labels and the log shows `system audio 0s`.
6. Repeat step 1 on the laptop speakers. Not a pass/fail: count the answers
   that appear twice (as `Them` and again as `You`). That number decides
   whether echo suppression is needed.

Memory with two recognizers: `--probe-meeting 300` during a call. Pass is the
same as before, under +60 MB/hour.


## Meetings reach the wiki (decision 13)

The script's live path is covered without Claude or the real vault:

```bash
tools/test-ingest-meetings.sh    # 31 cases, throwaway vault, fake claude
```

It covers the lock, a stale lock, the dirty-vault refusal, the no-since
refusal, oldest-first with max 1, the empty-meeting skip, the "named in
wiki/log.md" skip, and a timeout. It also covers a session that reports
failure, one that claims OK without doing the work, one that crashes, and
one that changes `raw/`. None of the failures is recorded as ingested.

**Switching it on.** First `claude` once in a terminal, to log in; the login
expired on 27 September. Then, from the main checkout:

```bash
tools/ingest-meetings.sh --dry-run --since 2026-09-01   # see what it would take
make install-ingest
launchctl kickstart gui/$(id -u)/dev.kilanii.speechlocal.ingest   # don't wait 30 min
tail -f ~/Library/Logs/SpeechLocal/ingest.log
```

**Dry run: pass.** It lists the meetings as `done` / `empty` / `THIS RUN` /
`later`. The six meetings ingested by hand in August show as `done (named in
wiki/source-summaries/)`. It says `vault: clean` and prints a prompt naming
exactly one `raw/meetings/` file. It writes nothing:
`~/Library/Logs/SpeechLocal/ingest.log` does not change.

**The first live ingest: pass criteria.** Record a short meeting, or use
the first one filed after install, and let one run happen:

1. The log shows `START`, `RUN raw/meetings/<file>`, then `OK <file> …
   cost_usd=… turns=…`, and no `FAIL` or `WARN`. Note the cost; it is
   the per-meeting price.
2. `git -C ~/Documents/second-brain log -1 --stat` is one commit. It
   touches only `wiki/`: a new `wiki/source-summaries/<Title> <date>.md`,
   `wiki/index.md`, `wiki/log.md`, and any canonical page it updated.
   Nothing under `raw/`.
3. The summary page has the exact frontmatter from
   `_system/page-conventions.md`: `type: source-summary`, `area:` set,
   `sources:` naming the raw file. It says what the recording actually was,
   and it labels inferences as inferences. Read it against the transcript: it
   invents nothing.
4. `git -C ~/Documents/second-brain status -sb` shows the vault is not ahead
   of origin, so the push worked.
5. `~/Library/Application Support/SpeechLocal/ingested.txt` gains that one
   line. A second `kickstart` logs `DONE nothing to ingest`, or takes the
   next meeting. It never repeats that meeting.
6. Make any uncommitted change in the vault (edit a note before Obsidian Git
   commits it), then `kickstart`. The log shows
   `REFUSE vault has uncommitted changes`, and nothing is written.

**Likely first failures, in the order they would appear.**
`FAIL macOS privacy denied access`: launchd's `/bin/bash` needs access to
`~/Documents`. If a prompt appears, allow it: that grants the Documents
folder only. If no prompt appears, the manual route is Full Disk Access for
`/bin/bash` (System Settings → Privacy & Security). That lets every bash
script read the whole disk, so it is a real trade-off. Neither route has
been tried yet. `claude exited 1` with an auth message: log in
again. `WARN … not pushed`: the agent has no ssh key; the commit is safe, so
push by hand.
