# Backtrack removes words the speaker marked, and nothing else

**Decided** 2026-09-27 · **Evidence** `docs/research/2026-09-27-wispr-flow.md`,
`doctor.log` counts below · **Overturns part of** decision 01

Decision 01 made light-touch "fix punctuation, change nothing else", and gave up
spoken self-corrections as the price. Omar asked for Wispr Flow's behaviour, and
Wispr's Backtrack deletes words: "coffee at 2 actually 3" becomes "coffee at 3".

**Clause overturned:** "What was given up: rules cannot resolve a spoken
self-correction." Rules can resolve the shapes where the speaker marks the
correction explicitly, and only those are resolved.

**New contract for light-touch:** change nothing except what the speaker marked,
in one of three shapes:

1. **A discourse marker set off by commas** — "like," and "you know," with a
   comma after them and a comma or sentence start before (`DiscourseFillers`).
   The log has `, like,` in 321 of 2,863 recognised dictations and `, you know,`
   in 113. A second, independent sample of 20 `, like,` hits found 19 fillers and 1
   meaning "about" ("the reaches, like, one or two" loses its hedge). Known
   misfires, pinned in the tests: "fruits, like, apples" ("such as").
2. **"scratch that"** — deletes its own sentence, or the previous one when it
   opens a sentence (`ScratchThat`). Wispr's documented trigger; 0 uses in the
   log so far, so it costs nothing where it is not said.
3. **A same-kind value swap** — a figure, weekday or month, a connector
   ("actually", "no", "sorry", "wait", "I mean"), and another value of the same
   kind (`CorrectedValue`). The log has 3 such swaps, all real corrections:
   "116, no, 125", "5280, wait, 539", "24, I mean, 8".

**Still refused:** a correction by restating ("send it Tuesday, I mean send it
on Wednesday") and a bare "I mean". Deciding those needs meaning, and decision
01's measurement stands: the on-device model could not do it either.

**Why not only on the rewrite key:** rewrite is 18 of 3,211 dictations, so
corrections there would reach 0.6% of use.

**The regression-corpus guard is unchanged.** `LightTouchInvariants` still
allows only `RulesCleanup.fillers` to vanish, and still runs `RulesCleanup`
alone. Each of the three stages has its own test that returns every corpus input
unchanged — so the invariants hold for ordinary speech, and words go only where
one of the three shapes is present.

English only; a Settings switch turns the whole stage off.
