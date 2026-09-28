# Describe it, get the code (C7): rejected on latency

**Decided** 2026-09-27 · **Evidence** `spikes/c7-describe-code/` (declaration
committed in 5f732de before the first model call; raw replies in `results/`)

The Build Order says C7 happens only if a spike beats decision 01's numbers for
code. This file was written, and the tasks, hidden tests and prompt committed,
before the model was called once.

## Verdict

**Rejected.** The declared reject condition "median latency > 6 s" fired on
both runs: **12.8 s** and **26.2 s**. Nothing was built. Following the
declaration, the prompt was not touched after the first run.

Quality was not the problem. The model wrote correct Python for **19 of 20**
descriptions in both runs, the replies were **byte-identical across runs
(20/20)**, and none contained prose. What failed is the wait: a reply that
takes 4–115 s after the key is released is not dictation.

**The latency was measured on a heavily loaded machine**, and that is the
single biggest caveat. Load average was 38–76 during run 1 and 33–190 during
run 2, from other sessions running test suites and builds in parallel. Latency
did not track reply length (`reverse`, 55 characters, took 11.7 s; `password`,
183 characters, took 3.5 s), which points at contention, not generation. Decision
01 already saw this model go from ~1 s to 4–15 s under load; here it went
further. How fast it is on an idle M1 was **not measured**.

## Declaration (verbatim, before measuring)

- Task set: 20 described functions a GCSE/IGCSE Computer Science student would dictate (e.g. largest in a list, count vowels, is prime, average of a list, reverse a string, linear search returning index or -1, bubble sort, fizzbuzz to n, celsius to fahrenheit, grade from a mark with the 70/60/50 bands, sum of digits, factorial, palindrome check, count words, find duplicates, binary search, times table, leap year, validate a password length ≥ 8 with a digit, mean of odd numbers). Write each description the way it would be spoken (no punctuation, lowercase, the way Apple's recognizer delivers speech), in Python.
- For each, a hidden test (3–5 asserts) written BEFORE seeing any model output.
- Predictions: at least 16/20 pass their tests; median wall-clock latency ≤ 4 s on this M1 for a cold session per call; zero outputs containing prose outside the code.
- Reject conditions: fewer than 14/20 pass, OR median latency > 6 s, OR any refusal/empty output rate above 2/20. If a reject condition fires, C7 is rejected: record it and stop — do not tune prompts until it passes (that would be fitting the test).

## Method, fixed before measuring

- **Tasks and tests:** `spikes/c7-describe-code/tasks.json` (the 20 spoken
  descriptions) and `spikes/c7-describe-code/hidden_tests.py` (the asserts).
  Numbers are written as digits because the recognizer turns spoken numbers
  into digits (decision 10: "ten" → `10`).
- **Prompt:** one, in `spikes/c7-describe-code/Spike.swift`, written in advance
  and not changed after the first run. Transformer framing, as
  `AppleCleanupEngine`'s full rewrite: the model is a code-writing function,
  the description is delimited, output only code, no fences, no explanation.
- **Model calls:** `SystemLanguageModel.default`, a fresh
  `LanguageModelSession` per task, `sampling: .greedy`. One throwaway warm-up
  generation first, as the app does at launch; the warm-up is not one of the 20.
  Latency is wall clock from session creation to the complete reply.
- **Scoring rules, decided before seeing output:**
  - A code fence in the reply is stripped and counted. Any text outside the
    fence, or a reply that does not parse as Python after stripping, counts as
    **prose outside the code**.
  - The code is run with `python3` (3.14) in a subprocess, stdin closed, 10 s
    limit, loaded as a module (`__name__` is not `"__main__"`); anything it
    prints while loading is discarded. Pass/fail is judged on the code after a
    fence is stripped; prose is counted separately against its own prediction.
  - The harness was checked before the first model call against hand-written
    reference solutions (20/20 pass) and deliberately broken ones (each failed
    for the stated reason).
  - The function under test: if exactly one top-level function is defined, that
    one; if more, the one no other defined function calls; if that is still
    ambiguous, the task fails as "ambiguous".
  - Inputs are passed in the order the description names them.
  - Functions that are asked to *print* (fizzbuzz, times table) are judged on
    captured stdout. A sort may sort in place or return the list. Duplicates are
    compared as a set. A grade letter is compared case-insensitively. Anything
    asked to "check if" is judged by truthiness.
- **Determinism:** the whole set is run twice; the two replies are compared
  byte for byte.

## Results

macOS 26.6.2, M1, `SystemLanguageModel.default` available. Optimised build
(`swiftc -O`) run from a terminal, 27 Sep 2026, 22:14–22:32. Warm-up
generation: 23.6 s (run 1), 31.9 s (run 2), not counted.

| # | Task (as spoken) | Tests | Run 1 | Run 2 |
|---|---|---|---|---|
| 1 | write a function that returns the largest number in a list | pass | 10.9 s | 27.4 s |
| 2 | write a function that counts the number of vowels in a string | pass | 4.7 s | 61.5 s |
| 3 | write a function that checks if a number is prime | pass | 15.1 s | 36.0 s |
| 4 | write a function that returns the average of a list of numbers | pass | 13.0 s | 27.8 s |
| 5 | write a function that reverses a string | pass | 11.7 s | 26.0 s |
| 6 | write a function that does a linear search on a list for an item and returns the index of the item or minus 1 if it is not found | pass | 12.6 s | 26.3 s |
| 7 | write a function that sorts a list of numbers using bubble sort | pass | 26.9 s | 21.6 s |
| 8 | write a function that prints fizzbuzz from 1 to n | pass | 60.1 s | 17.4 s |
| 9 | write a function that converts celsius to fahrenheit | pass | 27.2 s | 11.6 s |
| 10 | write a function that takes a mark and returns the grade a for 70 or more b for 60 or more c for 50 or more otherwise u | pass | 27.3 s | 14.1 s |
| 11 | write a function that returns the sum of the digits of a number | pass | 24.5 s | 8.9 s |
| 12 | write a function that returns the factorial of a number | pass | 21.2 s | 15.4 s |
| 13 | write a function that checks if a word is a palindrome | pass | 4.7 s | 30.4 s |
| 14 | write a function that counts the number of words in a sentence | pass | 6.3 s | 15.2 s |
| 15 | write a function that finds the duplicates in a list | pass | 11.8 s | 28.0 s |
| 16 | write a function that does a binary search on a sorted list for a target and returns the index of the target or minus 1 if it is not there | pass | 29.5 s | 114.6 s |
| 17 | write a function that prints the times table for a number from 1 to 12 | **FAIL** | 16.5 s | 77.3 s |
| 18 | write a function that checks if a year is a leap year | pass | 5.4 s | 36.8 s |
| 19 | write a function that checks if a password is at least 8 characters long and contains a digit | pass | 3.5 s | 22.4 s |
| 20 | write a function that returns the mean of the odd numbers in a list | pass | 5.0 s | 18.6 s |

Pass/fail was the same in both runs, since the replies were identical.

| | Predicted | Reject if | Run 1 | Run 2 |
|---|---|---|---|---|
| Tests passed | ≥ 16/20 | < 14/20 | **19/20** | **19/20** |
| Median latency | ≤ 4 s | > 6 s | **12.8 s** (3.5–60.1) | **26.2 s** (8.9–114.6) |
| Prose outside the code | 0 | — | 0 | 0 |
| Refusals / empty replies | — | > 2/20 | 0 / 0 | 0 / 0 |
| Code fence present (stripped) | — | — | 20/20 | 20/20 |
| Load average during the run | — | — | 38–76 | 33–190 |

- **The one failure:** the times table printed only the products (`7`, `14`,
  …) rather than a table line such as `7 x 1 = 7`. The test required the
  multiplier on each line; that was decided before the run.
- **Every reply came in a ```` ```python ```` fence**, despite "No markdown, no
  code fences" in the instructions. Decision 07 again: the instruction was
  ignored 40 times out of 40. Stripping a fence is trivial and deterministic,
  so this cost nothing here, but any build must strip it in code and not
  rely on the prompt.
- **The model added things nobody asked for**: `largest` raises on an empty
  list, `average` and `mean_odd` return 0 for no numbers, `vowels` counts
  capitals too. These are reasonable choices and none broke a test, but it is
  code the speaker did not dictate.

## If this is reopened

The replies are deterministic, so rerunning the same 20 on an idle machine
can only change the latency and cannot fit the tests. That is the one
re-measurement that would be fair: the same prompt, the same tasks, the same
harness (`swiftc -O -parse-as-library Spike.swift`, then `python3 check.py`),
on an idle M1 with the load average recorded. Declare beforehand that the reject
threshold stays at 6 s. Even if it passes idle, the app will sometimes run on
a loaded machine, and the build would need a visible "writing…" state and the
fallback of inserting nothing, as was planned.

## Run 3 — 27 Sep 23:28, load average 25–27 (lower, still not idle)

Same prompt, same 20 tasks, output unchanged. Median **11.6 s** (7.3–19.1),
warm-up 15.6 s. The fastest single reply (7.3 s) is above the 6 s reject line,
so the rejection stands at this load. Whether an idle M1 reaches 6 s is still
not measured; a VPN process was holding a full core throughout.

## Run 4 — 28 Sep 19:12, idle machine (load average 3.1 → 7.8 during the run)

The condition the earlier runs lacked. Output identical to run 1. Median
**6.9 s** (3.8–8.2), warm-up 13.2 s. **Above the 6 s reject line on an idle
machine: C7 is rejected, finally.** A spoken request that takes seven seconds
to type anything, and a first one that takes thirteen, is not dictation. The
code was right 19 of 20 times; speed, not quality, is what the on-device model
cannot give here.
