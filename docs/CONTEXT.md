# The change cycle

**Reads:** a symptom — a log line, a bad transcript, a UI that lies.
**Does:** the five steps below.
**Writes:** a commit, and a file in `decisions/` when something was settled.
**Human checks:** the app running, not the test suite.

## The unit of work

One observed problem, taken to evidence and back. Not a feature: features here
have arrived as three or four of these in sequence.

## The five steps

1. **Get the evidence before the theory.** The app logs raw and cleaned text
   for every dictation to `~/Library/Logs/SpeechLocal/doctor.log`. Read it
   before forming an opinion. Most "bugs" reported here were diagnosed wrongly
   until that file was opened.
2. **Find where it actually breaks.** The pipeline is long — recognizer →
   learned corrections → rules cleanup → insertion — and the layer that looks
   guilty usually is not. A comma vanishing was the comma *policy*, not the
   punctuation code that had just been written.
3. **Change the smallest thing.** Prefer a table entry over a new rule, a new
   rule over a new stage.
4. **Prove it.** A unit test for logic; `docs/verification.md` for anything
   involving audio, permissions, or the model. Both, when the change touches
   both.
5. **Write down what was settled**, if it cost more than an hour to learn — a
   file in `decisions/` for a design choice, an entry in `traps.md` for an
   environment behaviour.

## What earns a decision file

Something a future session would otherwise re-litigate or re-break: a rejected
alternative, a threshold with a number behind it, a constraint that looks
arbitrary. Each one names the evidence. A decision without evidence is an
opinion and belongs in a comment, not here.

## What does not belong here

Status. The commit log is the status, and a hand-maintained one drifts — see
`clone-run/STATE.md`, which is 340 lines of exactly that.
