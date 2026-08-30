# The vault receives source material, never the generated summary

**Decided** 2026-08-23 · **Evidence** the vault's own `raw/README.md`

The second brain separates `raw/` (source material, immutable) from `wiki/`
(the interpreted layer, built by its own `ingest` skill). Its README is
explicit: *"Do not place derived wiki pages, daily journal entries, content
drafts, or generated summaries here."*

A transcript and the user's own typed notes are source. An AI summary is
derived. So `VaultWriter` files the first two into `raw/meetings/` and keeps
the summary in the app; promotion into `wiki/` stays the vault's own skill's
job, where the cataloguing and linting live.

**Held to:** only ever creates files, never overwrites, never creates a vault
that is not there. `nothingOutsideTheMeetingsFolderIsTouched` and
`theGeneratedSummaryIsNeverFiledInRaw` pin both.
