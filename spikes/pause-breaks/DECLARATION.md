# Stage 9 spike — declared 2026-09-27, before any model call

**Question:** can Apple's on-device model decide whether a full stop the
recognizer put at a pause splits one sentence ("…doing like two, actually
three. Logs.") or ends a real one ("I'm stuck. Never mind.")?

**Set:** 44 short fragments from Omar's own doctor.log (`labelled.json`),
labelled by Claude before the run: 18 `merge`, 26 `keep`. 25 further cases
were excluded as not honestly decidable. The labels are one reader's
judgement, not ground truth.

**Baseline:** the rule "merge every such fragment" is right on 18/44 (41%).

**Prompt:** fixed below; not tuned after the first run.

**Predictions:** at least 36/44 agree with the labels (82%); at most 3 wrong
merges (a wrong merge costs a sentence boundary the speaker meant); median
latency at most 1.0 s per case.

**Reject conditions:** fewer than 33/44 agree (75%), OR more than 5 wrong
merges, OR median latency above 2 s on a machine with load average under 20.
If latency cannot be measured on a quiet machine, the latency verdict is
recorded as not measured, and the stage stays waiting.
