# Light-touch cleanup is rules, not the on-device model

**Decided** 2026-08-16 · **Evidence** `clone-run/research.md` Spike 3

The obvious design was to send every dictation through `FoundationModels` for
punctuation and filler removal. Measured, it fails twice over: a median of
**7.2 s** for novel input with **0 of 10** inside the 1.5 s budget, and on
**2 of 10** corpus items it silently truncated or emptied the output — no
error, `refusals: 0/10`.

For a mode whose contract is "fix punctuation, change nothing else", losing the
user's words is a correctness failure, and an unpredictable 1–8 s wait defeats
the point of dictation.

So light-touch is `RulesCleanup`: deterministic, sub-millisecond, structurally
incapable of dropping content. The model is kept for full rewrite, where
rewording is the point and the user asked for it.

**What was given up:** rules cannot resolve a spoken self-correction ("Monday,
no actually Tuesday"). Neither could the model, given an explicit rule and a
worked example — so nothing was lost by choosing rules.
