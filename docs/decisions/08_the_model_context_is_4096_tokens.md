# The on-device model's context is 4,096 tokens, and that shapes the summariser

**Measured** 2026-09-06 · **Evidence** a 99-minute recording that failed

Apple does not document the limit. It was found by exceeding it:

```
Content contains 9104 tokens, which exceeds the maximum allowed context
size of 4096.
```

That ceiling covers **prompt and answer together**, so a call that fills it
with input has nowhere to put the reply.

## What the recording showed

| | |
|---|---|
| Length | 98.9 minutes, 19,498 words |
| Windows at 1,200 words | 17, each ~1,590 tokens — every one fit |
| Time for the map phase | ~25 minutes, about 90 s per window |
| Merging 17 digests in one call | 9,104 tokens — **refused** |

So the chunker was right and the merge was wrong. Seventeen model calls
succeeded over twenty-five minutes and the final step threw all of it away.

## What follows

**Merging is hierarchical.** Digests are folded in batches that fit the budget,
and the batches folded again, until one call can write the note. A single merge
cannot work at any recording length worth summarising.

**The map phase is never lost.** If the final write fails, the folded notes are
returned as the note. Twenty-five minutes of work must not depend on the last
call succeeding.

**A window is a call, and a call is ~90 seconds.** Window size is therefore a
running-time decision as much as a quality one: 1,800 words puts a 99-minute
recording at 11 windows instead of 17. The ceiling on window size is the
context, minus room for the instructions and the answer.

## 2026-09-15 — ask less, guarantee instead

A 70-minute recording (12,838 words) reached the final write at **5,123
tokens** and was refused. Its map notes were 297 bullets, 3,418 words — **26% of
the transcript** — from a prompt asking for "terse" notes. Every safeguard to
that point asked the model to be shorter; decision 07 had already shown that
does not hold.

So the length is now bounded in code before the call. The map and fold prompts
carry hard ceilings (8 bullets per window, 25 per fold), and `fitToBudget` keeps
an evenly spaced subset of note lines if the notes are still over budget, so the
write cannot be handed more than it can read and the note still spans the whole
recording.

**Not yet measured:** whether the ceilings hold on a real recording, and how much
the even sampling costs the note. That recording predates the incremental
reading from 12 Sep, which has not yet run against a meeting either.
