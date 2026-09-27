# Meetings reach the wiki through a Claude session, run outside the app

**Decided** 2026-09-27 · **Evidence** `tools/test-ingest-meetings.sh` (31 cases
against a throwaway vault and a fake `claude`), the dry run in
`docs/verification.md` · **Builds on** decision 06

M8 asks that a meeting the app files reaches the vault's `wiki/` with no manual
step. Until now it stopped at `raw/meetings/`, and six of the ten files there
were ingested by hand, days later. Four never were.

## Options

**A. The app writes the wiki pages itself, from its on-device summary.**
No network, no quota, instant. Rejected on three counts. Decision 06 already
settled that the summary is derived material and the vault's own `ingest`
skill promotes sources. The vault's `CLAUDE.md` requires checking
`wiki/index.md` before creating a page, and `_system/structure.md` requires
merging into the canonical owning pages and keeping cluster link discipline.
None of that is text generation. It is judgement over the whole wiki, which a
4,096-token on-device model cannot see (decision 08). And that model
invented a person, a company and a definition from one garbled transcript
(verification.md, "What no probe covers"). Pages like that, written
unattended into the interpreted layer, would be worse than no page.

**B. A queue plus a separate Claude session, outside the app. (Chosen.)**
The app is unchanged: `VaultWriter` files source to `raw/meetings/` and
never touches the network. A launchd agent runs `tools/ingest-meetings.sh`
every 30 minutes. For each meeting not yet ingested (at most one per run by
default), it starts `claude -p` in the vault and hands it the vault's own
ingest skill, `structure.md` and `page-conventions.md`, scoped to that one
file. Interpretation happens where the vault's rules are enforced, by a model
that can read the whole wiki.

**C. Manual.** Omar runs the ingest skill when he remembers. This is the
status quo, and it is what left four meetings unread.

## Why B holds the constraints

- **The app stays offline.** The only network use is the script's, and the
  script is not part of the app. Uninstalling the agent returns everything to
  exactly how it was.
- **raw/ stays immutable, and this is checked, not asked for.** The session
  can only edit `wiki/` (`Edit(//<vault>/wiki/**)` is allowed; `raw/**` is
  denied; `dontAsk` turns any other write into a denial). After the session,
  the script also checks git: any change under `raw/`, committed or not, fails
  the run as `RAW CHANGED`. Nothing is reverted automatically, because
  reverting is itself a write to the vault.
- **A zero exit is not trusted.** `claude -p` exits 0 whenever the CLI
  finishes, not when an ingest succeeded. A file is recorded as ingested only
  when four things hold. The session's last line is
  `INGEST-RESULT: OK`. A page in `wiki/source-summaries/` names the file.
  `wiki/log.md` names it. A new commit exists and the vault is clean. The
  vault skill's own rule is "never consider a source processed unless a
  valid source-summary page exists for it".
- **Omar's edits are never mixed in.** If `git status --porcelain` is
  non-empty, the run refuses, before every meeting and not only at the start.
- **Already ingested means any of three records.** The state file is
  `~/Library/Application Support/SpeechLocal/ingested.txt`, outside the vault
  and the repo. A file also counts as done if its name appears in
  `wiki/log.md` or in a source-summary page. The last check is needed:
  the six meetings ingested by hand are named only in their source-summary
  `sources`, not in the log, and a log-only check would have ingested all six
  again.
- **No backlog by surprise.** `make install-ingest` writes the install day to
  `ingest-since` once. Files dated earlier are ignored. Taking the backlog
  is a deliberate `--since all` run.
- **Empty recordings cost nothing.** A file with no notes and no transcript
  words is never sent to Claude. It is also never recorded as ingested.

## The cost

- **Claude quota for every meeting.** A long meeting (the 7 September file
  is 70 KB) means reading the transcript, `wiki/index.md` and the pages
  it touches. The log records `cost_usd` and `turns` per run, from the CLI's
  JSON output. On a subscription login that figure is an API-price
  equivalent drawn from the plan's usage, not a charge.
- **It needs the network and a logged-in `claude` CLI.** The login expired
  on 27 September. Until Omar logs in again, every run fails, and says why.
- **Ingest is delayed, not instant.** It takes up to 30 minutes after filing,
  plus the session's own time. One meeting per run keeps a backlog from
  spending the quota in one burst.
- **The ingest is only as good as one unattended session.** Nobody reviews
  a page before it is committed. The commit is the review point: every
  ingest is one commit naming its pages, so it can be read and reverted.

## What fails, and how it shows

Every line is in `~/Library/Logs/SpeechLocal/ingest.log`, prefixed with time
and run id. Each session's full JSON output and stderr are kept in
`~/Library/Logs/SpeechLocal/ingest-runs/`.

| Line | Meaning | Recorded as ingested? |
|---|---|---|
| `REFUSE no since date` | Not installed with `make install-ingest` and no `--since` | — |
| `REFUSE vault has uncommitted changes` | Omar (or Obsidian) has unsaved work; retried next run | no |
| `REFUSE another run holds the lock` | Previous run still going | — |
| `WARN removing stale lock` | A run died without cleaning up; this run carries on | — |
| `FAIL macOS privacy denied access` | launchd's bash cannot read `~/Documents` (TCC) | — |
| `FAIL claude CLI not found` | PATH in the plist does not reach `claude` | — |
| `FAIL … claude exited N … stderr: …` | Login expired, network down, API error | no |
| `FAIL … timed out after Ns; killed` | Session exceeded `INGEST_TIMEOUT` (1200 s) | no |
| `FAIL … session did not report success` | Session ended with `FAILED` or no result line | no |
| `FAIL …: no source-summary names it` (etc.) | Session claimed OK, but the vault disagrees | no |
| `FAIL RAW CHANGED during …` | Something under `raw/` changed. Inspect by hand | no |
| `WARN … committed but not pushed` | Ingest is done; push failed (ssh agent, network) | yes |
| `OK … cost_usd=… turns=…` | Ingested, checked, recorded | yes |

A failed meeting is retried on the next run, because it was not recorded. A
meeting that fails every time holds up the queue behind it, since the queue
goes oldest first. The log shows the same `FAIL` each half hour. That is
deliberate: skipping it would hide it.

## Not verified

No real `claude` session has run through this. The CLI login is expired, and
a live run spends quota and writes to the vault. Three things are unproved.
The permission rules are taken from the docs, not observed. launchd's access
to `~/Documents` is unproved: the docs confirm background processes can get
`Operation not permitted` there. `git push` over ssh from a launchd agent is
unproved. The first live ingest is the acceptance test, in
`docs/verification.md` under "Meetings reach the wiki".
