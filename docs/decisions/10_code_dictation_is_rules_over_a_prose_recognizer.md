# Code dictation is rules over a prose recognizer

**Decided** 2026-09-15 · **Evidence** a 30-line spike, below

Code dictation got its own hotkey (a third `CleanupMode`, `.code`), and
`PythonDictation` does the work with rules and a name table generated from
the libraries. Before any grammar was written, the spike measured what the
recognizer does to spoken Python.

## How it was measured

Thirty spoken lines of Python were recorded with macOS `say` (one voice, not a
person) and fed to `SpeechLocalStdin`, the app's own engine.

**Every result here comes from a synthetic voice.** How the recognizer handles
Omar's voice through a real microphone has not been measured.

## What the recognizer does to code

- **It writes code as prose.** It adds a capital first word, a closing full
  stop, and commas at pauses ("input, quote, what is…"). Some spoken symbols it
  converts itself ("pd dot read" → `pd.read`, "ten" → `10`) and others it
  leaves as words. The rules therefore lowercase everything outside strings and
  treat most punctuation as noise.
- **It mishears short keywords and library names.** Heard without padding:

  | Spoken | Heard |
  |---|---|
  | if x | "FX" / "Effect" |
  | elif x | "Male effects" / "Lifex" |
  | for i in | "For iron" |
  | while | "Wild" |
  | import numpy | "Important appeal" |
  | sklearn | "Skullern" / "Sklern" |
  | matplotlib | "Matt Plotlip" |
  | linspace | "lenspace" |
  | iloc | "ilock" |
  | dot append | "don't depend" |
  | as e | "Z" |

- **A single-word line came back empty.** "else" and "try" gave nothing at all.

## What was tried against it

| Change | Result |
|---|---|
| Bias terms (`contextualStrings`): 57 keywords, library names and commands | **No effect.** Output identical, line for line. Matches the earlier "Higgsfield" finding. |
| 0.5 s of silence either side of the clip | Recovered "else", "try", "while" and "linear". **Adopted for code mode** in `Listener.transcribe`. |
| Custom language model (`SFCustomLanguageModelData` → `DictationTranscriber.customizedLanguage`) | See the next section. **Not adopted.** |

## The custom language model

A code-relevant-token pass count put the transcribers at:

| Transcriber | Lines passing |
|---|---|
| SpeechTranscriber | 17/30 |
| DictationTranscriber | 13/30 |
| DictationTranscriber + custom LM | 19/30 |

The custom model needs a switch to the weaker transcriber, so its net gain
over what the app already uses is +2 lines. Several templates overlapped the
test lines, so even that gain is optimistic.

It failed silently in two ways:
1. The speech daemon cannot read model files under `/private/tmp`.
2. The model only applies in the process that prepared it.

Preparing it took 7.4–12 s, which would be paid on every launch.

Revisit only with real recordings of a real voice, and only if the rules
cannot absorb the mishearings.

## What the rules do about mishearings

- **Library names:** a table of 5,965 names was generated from Python 3.14,
  numpy, pandas, matplotlib, seaborn, scikit-learn, scipy and torch
  (`scripts/python_names.py`). After a known owner such as `np.` or `df.`, a
  name within one edit is corrected ("lenspace" → `linspace`, "ilock" →
  `iloc`). After an unknown owner nothing is guessed, since that is someone's
  own identifier.
- **Keyword mishearings:** fixed only by a table of measured confusions
  ("for iron" → `for i in`). Nothing can recover "Effect" as `if x`.
  Single-letter variable names are the weakest input, and a user who hits this
  should prefer longer names.

## Rejected

- **The on-device model** (decision 01): 7.2 s median and silent truncation.
  In code, one wrong character is a program that does not run.
- **Automatic switching by frontmost app:** a commit message typed in VS Code
  would come out as code, and browser notebooks can't be detected.
- **A menu toggle:** forgetting that it is on turns prose into code with no
  warning.

## Addendum 2026-09-15 — first dictation by a real voice

Omar dictated a grade-from-a-mark solution into Trace Table (CodeMirror in
Arc; insertion via paste). From `doctor.log`, what the synthetic voice had not
shown:

- **"next line" was read as the builtin `next`** — `next(line_case, …)`. It is
  now a command that presses Return, so the editor indents. That reverses
  "never synthesize Return" for this one case, deliberately: it only happens in
  code mode and only when the speaker says it.
- **"or" is heard as "are", or dropped**: "greater than are equal to",
  "greater than equal to". Both are now `>=`, as is "is greater than …".
- **"sixty" and "seventy" came back as 16 and 17.** Not fixable in rules — a
  16 is a legal number. Say "six zero".
- **`match` and `case` are soft keywords** and were not in the table; the
  recognizer also ran "match mark" together. Both handled at line start.
- **A pause comma after the last figure was treated as spoken** ("50," →
  `50,:`). A comma is now hard only between two figures.
- Several presses used Fn (light-touch) instead of the code key, producing
  "Print F." — not a bug, but the pill colour is the only cue.

### Second run, same evening

- **`elif` → "LF" in 6 of 7 dictations, "L if" in 1; `else` → "L" and "LS".**
  Consistent enough for a line-start table (`openingKeyword`). A bare "L" is
  `else` only when a colon or nothing follows, so `l = 5` survives. "else if"
  and "otherwise" are accepted as reliably-heard alternatives.
- **`elif`/`else`/`except`/`finally` after "next line" dedent by one on their
  own.** Every one of them sits one level out from the line above, whether
  that line was the header or its body; a deeper step-out is still spoken.
- **"next line" once arrived as "next time"**, now a line break.
- **"capital A" inside a string was kept as the words.** "capital" and
  "all caps" now apply inside strings.

### Third run: indentation is text, not keystrokes

The "next line" design pressed Return and Backspace and left indentation to
the editor. In Trace Table (CodeMirror in Arc, paste insertion) Return landed
with no indent, so the Backspace meant to step out for `elif` deleted the line
break instead: every `elif` came out glued to the `print` above it
(`print("A")elif mark >= 60:`). Why the editor did not indent was not
established — keystroke timing against an asynchronous paste, or modifier
state on the synthetic event, are both plausible and neither was measured.

**Rejected: keystrokes.** Their effect depends on each editor's handlers and
on timing, and cannot be observed from here. **Adopted:** `PythonDictation.block`
writes the line breaks and four-space indentation into one paste, starting
from the caret line's indentation when accessibility publishes it. This also
restores "never synthesize Return" without exception.

**Not verified:** that CodeMirror and VS Code leave a multi-line paste's
indentation alone (neither re-indents on paste by default, per their
settings; not run). Where the caret line is not published, a block started
inside an indented body is placed from column 0 on its later lines.
