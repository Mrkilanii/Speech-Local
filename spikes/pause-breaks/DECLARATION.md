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

## Result — run 1, 27 Sep 23:21–23:27 (load average 81 → 17 during the run)

| | Predicted | Reject if | Actual |
|---|---|---|---|
| Agreement with labels | ≥ 36/44 | < 33/44 | **19/44** (43%) |
| Wrong merges | ≤ 3 | > 5 | **22** |
| Missed merges | — | — | 3 |
| Median latency | ≤ 1.0 s | > 2 s at load < 20 | **8.2 s** (load above 20 — not a clean measure) |

**Rejected** on agreement and on wrong merges; either alone fires. The model
answered CONTINUES on 36 of 44 — it treats almost every pause as mid-sentence,
which is the "merge everything" rule (41%) with an eight-second wait. Latency
was not measured cleanly, and does not need to be: the accuracy fails first.
The prompt is not being tuned against these labels.

**What this leaves:** pause-split sentences stay unfixed. The remaining paths
are a better model than the on-device one (not available offline on this
Mac), or a signal the recognizer has and the transcript does not — the pause
length itself. SpeechAnalyzer reports each segment's time range; a full stop
after a pause under ~300 ms is more likely mid-sentence. That is measurable
from audio and is the next thing worth trying.
