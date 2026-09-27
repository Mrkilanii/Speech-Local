# Describe it, get the code (C7)

**Status** declared 2026-09-27, not yet measured · **Evidence** `spikes/c7-describe-code/`

The Build Order says C7 happens only if a spike beats decision 01's numbers for
code. This file was written, and the tasks, hidden tests and prompt committed,
before the model was called once.

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
