# Build goal: FlowLocal — a fully local Wispr Flow clone for macOS

> **HOW TO RUN THIS** — two moves in a fresh Claude Code session, opened in the
> target repo (`/Users/MrKilanii/Documents/whisper copy`, or wherever you rename
> it):
>
> 1. Paste everything below the line as your first message.
> 2. Then set the finish line:
>    `/goal "make doctor prints ALL CHECKS PASS in this conversation, with every must-have feature exercised"`
>
> **Before you start:** enable Apple Intelligence (System Settings → Apple
> Intelligence & Siri) and let its models finish downloading. The cleanup engine
> cannot run without it.

---

You are building **FlowLocal** — a menu-bar macOS app that turns speech into
finished text in whatever app has focus. Hold a hotkey, speak, release; cleaned
prose appears at the cursor. It is a local replacement for Wispr Flow, which is
cloud-based and subscription-priced. **Nothing may touch the network at runtime.**

Build it from the locked spec below. Work in the plan's de-risk order, verify as
you go, and show each milestone working before moving on.

## What we're building (v1 must-haves)

1. **Hotkey → speak → auto-type.** Global hotkey anywhere in macOS; transcript
   inserted at the cursor in the frontmost app. This is the whole product.
2. **Local AI cleanup.** On-device LLM strips disfluencies, fixes punctuation and
   casing. Two modes on two keys: light-touch and full rewrite.
3. **Custom dictionary.** User-supplied names, jargon, acronyms survive
   transcription.
4. **Menu bar app + settings.** Status item (idle/recording/processing) plus
   preferences for hotkeys, mic, and dictionary.

## Hard constraints (non-negotiable)

- **100% local.** No network calls at runtime for any core function. No cloud
  transcription, no cloud LLM, no fallback that phones home. Verify with wifi off.
- **No account, no subscription, no telemetry.**
- **Snappy** — target ~1.5 s from hotkey release to text. This is what M1
  measures; if it can't be met, the plan says how to degrade, and you follow that
  rather than quietly shipping something slow.
- **Ships as a real `.app`** that survives reboots in the menu bar.

## Explicitly out of scope (v1)

iOS/iPadOS or any sync; any cloud, account, or telemetry; languages beyond
English; auto-segment; meeting recording. Per-app tone profiles and transcript
history are deferred but must not be architecturally precluded.

## Verified environment — measured on this machine, do not re-derive

- Apple **M1 base**, 16 GB, macOS **26.6.1** (build 25G76)
- **Command Line Tools 26.5**, SDK 26.5, Swift **6.3.3**
- **No Xcode, and none needed.** `swift build` is sufficient. `metal` is absent
  from CLT and always will be — only the MLX contingency would need it.
- **0 codesigning identities** — M0 creates a self-signed cert. This is not
  optional; without it macOS silently drops Accessibility on every rebuild.
- `SpeechTranscriber`: **verified working**, `en-US` installed, no download,
  no Apple Intelligence needed.
- `FoundationModels`: compiles and resolves; was
  `unavailable(appleIntelligenceNotEnabled)` at plan time. Re-check first.

Three traps already paid for — do not rediscover them:

1. A bare SPM binary **crashes** on `NSStatusBar`. You must assemble a real
   `.app` bundle with `Info.plist` and `LSUIElement=1`.
2. `AXIsProcessTrusted()` returns **true** from a terminal because it inherits
   the terminal's TCC grant. Test permissions only from inside the bundle.
3. `kAXSecureTextFieldRole` does not exist. Secure fields are identified by
   **subrole** (`kAXSecureTextFieldSubrole`).

## Licensing — binding

The repo will be published under **MIT**. **VoiceInk is GPL-3.0: do not copy,
adapt, or transcribe its code.** Reading it to understand technique is fine;
reproducing its structure or lines is not. When in doubt, work from Apple's
documentation. This is a legal constraint, not a style preference.

## How to proceed

1. Re-verify the environment first — especially
   `SystemLanguageModel.default.availability`. If it is still unavailable, stop
   and tell the user to enable Apple Intelligence.
2. Build in the plan's de-risk order. **M0 and M1 come before any pipeline
   code** — they answer whether the architecture holds at all.
3. M0 needs the user's password (certificate, permission grants). Pause and ask.
4. After each milestone, run it and show it working before moving on.
5. If M1's measurements miss the budget, follow the plan's documented fallbacks.
   Do not silently accept worse latency.

---

# THE LOCKED PLAN

# Plan — FlowLocal: a fully local Wispr Flow clone for macOS

## Context

Wispr Flow is hotkey dictation that inserts *finished* text at the cursor in any
app — speak, release, polished prose appears. It costs a subscription and sends
audio to the cloud. This rebuilds it to run entirely on-device.

Target machine (verified 2026-08-15, post-upgrade — measured, not assumed):
**Apple M1 base, 16 GB, macOS 26.6.1 (Tahoe, build 25G76), Command Line Tools
26.5, SDK 26.5, Swift 6.3.3, zero codesigning identities, Apple Intelligence
OFF.**

Four spike results shape everything:

1. SwiftUI/AppKit/AVFoundation/CoreML compile and link against the CLT SDK.
2. A bare SPM binary **crashes** on `NSStatusBar` (`CGSConnectionByID`
   assertion) — a real `.app` bundle is mandatory.
3. `AXIsProcessTrusted()` returns `true` from a terminal because it **inherits
   the terminal's TCC grant** — any permission test run from a shell lies to you.
4. **`SpeechTranscriber` and `FoundationModels` both compile against CLT 26.5
   with no Xcode.** At runtime `SpeechTranscriber` is fully working with `en-US`
   already installed; `FoundationModels` returns
   `unavailable(appleIntelligenceNotEnabled)`.

**No Xcode required.** MLX's Metal shaders were the only thing that forced it,
and MLX is gone from the primary path. `metal` is absent from CLT and always
will be. Xcode returns as a requirement *only* if M1 forces the MLX fallback.

**Blocking user action:** enable Apple Intelligence (System Settings → Apple
Intelligence & Siri) and let its models download. `FoundationModels` is a runtime
feature flag — until it flips, cleanup cannot be built or measured.

Research and sources: `clone-run/research.md`. Scope: `clone-run/scope.md`.
This plan incorporates a Codex adversarial review (`clone-run/PLAN-REVIEW-LOG.md`).

**Outcome:** a menu-bar `.app` where two hotkeys turn speech into cleaned text
in the frontmost app, with no network at runtime.

---

## Locked decisions

| Decision | Choice |
|---|---|
| Backends | ASR and cleanup behind protocols. **Apple-native is now the primary path** (`SpeechTranscriber` + `FoundationModels`); MLX/Parakeet demoted to a contingency backend if M1 fails. |
| Activation | Two hotkeys, each with two gestures: hold-to-talk, or double-tap to toggle hands-free. |
| Modes | Key 1 = light-touch (punctuation, caps, fillers, dictionary; no rewording). Key 2 = full rewrite. |
| Latency | LLM in both modes, streamed — but committed **per validated sentence**, not per word (see below). |
| Dictionary | Explicit alias map, whole-token matching only, plus a cached LLM prompt prefix. |
| Failure | Degrade loudly, never lose text. |
| Release | **Public GitHub repo under MIT**, source-only distribution, design docs published. |

### Licensing discipline — binding on the build

The repo is **MIT**. Every dependency is compatible: FluidAudio (Apache-2.0),
Parakeet TDT 0.6B (CC-BY-4.0, commercial use permitted), Qwen3-1.7B-4bit
(Apache-2.0), MLX Swift (MIT).

**VoiceInk is GPL-3.0.** It is the closest reference implementation and it solves
the two hardest problems here — system-wide insertion and the hotkey event tap.
Under MIT, its code **must not be copied, adapted, or transcribed**. Reading it
to understand *technique* is fine; reproducing its structure or lines is not.
When in doubt, work from Apple's documentation instead. This is a legal
constraint, not a style preference.

**Parakeet's CC-BY-4.0 requires attribution** — the README needs a credits
section naming NVIDIA's model, FluidAudio, Qwen/mlx-community, and MLX.

### Revision forced by review: sentence-level commits

The original design streamed at word boundaries. That is unsafe: a model can
open with `Sure,` or a markdown fence, and full-rewrite mode may **reorder**
material already committed to the document. Neither is recoverable once text is
in someone else's app.

- Buffer generated tokens; validate the prefix against an expected output shape
  (no preamble, no fence, no heading) **before the first commit**.
- Commit at **sentence** boundaries, decoded through the tokenizer's incremental
  decoder (tokens are not characters — byte-fallback tokenizers split UTF-8).
- **Full-rewrite mode buffers the entire output and inserts once.** Reordering
  makes streaming incoherent there. Streaming applies to light-touch only, where
  output order tracks input order.
- Perceived latency in light-touch is first-sentence, not first-token. Still far
  better than waiting for the whole utterance.

---

## Architecture

```
FlowLocal.app                       (LSUIElement menu-bar app)
  Core/
    HotkeyManager.swift             CGEventTap; constant-time callback; handles
                                    tapDisabledByTimeout/ByUserInput; tags own synthetic events
    AudioCapture.swift              native-format tap → AVAudioConverter → 16 kHz mono
                                    lock-free SPSC ring buffer; continuous preroll
    ASREngine.swift                 protocol; streaming-capable, not unbounded [Float]
      AppleASREngine.swift            SpeechTranscriber + SpeechAnalyzer (PRIMARY)
      ParakeetASREngine.swift         FluidAudio — CONTINGENCY ONLY, build if M1 fails
    CleanupEngine.swift             protocol { stream(String, Mode) -> AsyncThrowingStream<String> }
      AppleCleanupEngine.swift        FoundationModels LanguageModelSession (PRIMARY)
      MLXCleanupEngine.swift          CONTINGENCY ONLY — reimposes the Xcode requirement
    VocabularyMatcher.swift         explicit aliases, whole-token, protects numbers/URLs/code
    TextInserter.swift              capability probe → AX or paste; actor-serialized
    DictationPipeline.swift         session IDs; owns cancellation + degradation
  UI/
    StatusItemController.swift      full lifecycle state machine
    SettingsView.swift              hotkeys, mic, model, dictionary, prompts
    DiagnosticsView.swift           in-app Doctor + owned scratch text field
  Support/
    Permissions.swift               AX, Input Monitoring, mic; best-effort Settings deep links
    ModelStore.swift                NOT BUILT on the primary path — the OS owns the
                                    models. Contingency only, with MLX.
  build/
    Makefile                        swift build → assemble .app → sign inside-out
                                    (no xcodebuild; CLT 26.5 is sufficient)
    Info.plist                      LSUIElement=1, NSMicrophoneUsageDescription, stable bundle ID
```

### Concurrency and safety rules (from review)

- Every dictation run gets a **monotonic session ID**. Check it before every
  side effect. Aborting cancels upstream generation, not just insertion.
- `TextInserter` is an **actor** — insertion ownership is serialized.
- Synthetic `CGEvent`s carry a private user-data tag; the abort guard ignores
  only tagged events, so the app never aborts on its own ⌘V.
- The event-tap callback does **no** allocation, locking, UI, or logging — it
  enqueues a minimal record and returns.
- The audio render callback writes only into a preallocated ring buffer;
  conversion and file I/O happen off the real-time thread.
- Model output is bounded: max tokens relative to transcript length, wall-clock
  timeout, stop sequences, repetition control. Violation → insert raw transcript.
- Toggle mode has a documented **maximum duration** and internal chunking; a
  hands-free session cannot grow unbounded in RAM.
- Settings are **snapshotted per session**; changes apply to the next one.

### Engines (primary path — verified available)

| | ASR | Cleanup |
|---|---|---|
| API | `SpeechTranscriber` + `SpeechAnalyzer` (`import Speech`) | `SystemLanguageModel` / `LanguageModelSession` (`import FoundationModels`) |
| Model | OS-managed, **`en-US` already installed** | Apple's on-device ~3B, OS-managed |
| Download | **none** | Apple Intelligence assets, OS-managed |
| Requires Apple Intelligence | **No** — verified working with it off | **Yes** — currently `appleIntelligenceNotEnabled` |
| Builds with CLT 26.5 | ✅ verified | ✅ verified |

Neither ships weights in the repo, so `ModelStore`, checksums, atomic staging,
and version migration are all **cut**. The OS owns model lifecycle.

**Guardrails are the new unknown.** `FoundationModels` can refuse input — it is
a safety-filtered model, and dictation is arbitrary user speech. A refusal in
light-touch mode must be indistinguishable from any other cleanup failure:
insert the raw transcript, notify, never lose text. M1 must probe this
deliberately with realistic dictation, including profanity and blunt phrasing,
because a refusal path that only appears in production is a data-loss bug.

**Availability is a runtime feature flag, not a guarantee.** Check
`SystemLanguageModel.default.availability` at launch *and* before each session;
handle `.unavailable` by degrading to rules-only cleanup with a visible status,
not by crashing or silently emitting raw text.

**Contingency (only if M1 fails):** `mlx-community/Qwen3-1.7B-4bit`, 4-bit,
~968 MB, Apache-2.0, listed in `mlx-swift-lm`'s `LLMModelFactory.swift`. Note
Qwen3 emits `<think>…</think>` blocks by default — fatal for dictation latency,
must be disabled via `enable_thinking=false` or `/no_think`. Choosing this path
reimposes Xcode and restores `ModelStore`.

### Insertion primitive (concrete API sequence)

Ranges are **UTF-16 `CFRange`** throughout — the authoritative coordinate system
for every guard in this plan.

1. Focused element: `AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
   kAXFocusedUIElementAttribute)`.
2. **Reject secure fields:** read `kAXSubroleAttribute` and compare against
   `kAXSecureTextFieldSubrole` — secure fields carry role `AXTextField` and are
   distinguished only by **subrole**. Abort without reading or writing.
3. **Capability probe:** `AXUIElementIsAttributeSettable(el,
   kAXSelectedTextAttribute)`. Not settable → paste fallback.
4. **Insert:** set `kAXSelectedTextRangeAttribute` to a zero-length `CFRange` at
   the insertion point (`AXValueCreate(.cfRange, …)`), then
   `AXUIElementSetAttributeValue(el, kAXSelectedTextAttribute, text)`. Setting
   selected text on a collapsed range *is* the insertion.
5. **Verify:** read back `kAXSelectedTextRangeAttribute`, and read a short
   sentinel around the insertion point via
   `AXUIElementCopyParameterizedAttributeValue(el,
   kAXStringForRangeParameterizedAttribute, …)`. Parameterized attributes are
   **read-only** — they verify, they never write.
6. Any mismatch → stop streaming, fall back per the rules below.

### Partial-commit transaction rules

Streaming means text is already in someone else's document when things go wrong.
Two rules govern that:

- **Never re-insert what was already committed.** Track `committedUTF16Count`
  for the session. On timeout, cancellation, or validation failure, insert only
  the **uncommitted remainder** — never the whole raw transcript. If the
  committed extent can't be established with confidence, insert nothing further,
  put the complete text on the clipboard, and notify.
- **Re-validate before every commit, not just at session start.** Between
  sentences the user can move the caret or edit inside the *same* field, which a
  PID/focus check cannot detect. Before each commit, confirm the selected range
  equals the expected post-commit range and the sentinel still matches. On
  mismatch: abort streaming, buffer the remainder, deliver via clipboard.

Pasteboard etiquette: record `changeCount`, write with a session marker,
revalidate frontmost PID **and** focused element immediately before posting ⌘V,
and restore the prior contents only if the pasteboard still carries our marker.
Promised/lazy items cannot be faithfully restored — document that. If paste
fails, the transcript **stays** on the clipboard rather than being restored away.

---

## Milestones, in de-risk order

**M0 — Signed bundle vertical spike.** *Everything downstream is untestable
until this holds.* No Xcode needed — `swift build` against CLT 26.5. Makefile
assembles a real `.app`; create a
**stable self-signed certificate** and sign **inside-out** (nested dylibs and
frameworks first) — ad-hoc signing mints a new identity per build, so macOS
silently drops Accessibility and stops re-prompting. Pin the install path.
The spike must exercise, from inside the bundle: status item, event tap creation,
mic authorization, a native-format audio tap, an AX query, and a synthetic paste.
**Acceptance:** grant permissions once, rebuild three times, all grants survive;
`codesign -dvvv --strict` clean.

**M1 — `FoundationModels` feasibility spike.** *The largest remaining unknown,
and the only thing standing between this plan and a settled architecture.*
**Requires Apple Intelligence to be enabled first.** Run inside the **release**
`.app`, not from a terminal. Measure, on this base M1:

- first-token and total latency for a light-touch cleanup of a one-sentence
  utterance, and of a 100-word utterance;
- peak memory with `SpeechTranscriber` also active;
- behavior with **wifi off** — must be identical (this is the 100%-local claim,
  and Apple's framework is on-device-only with no server path, so verify it);
- **guardrail probing:** realistic dictation including profanity, blunt
  phrasing, medical and legal words. Record every refusal.

**Acceptance:** offline generation from the assembled bundle with numbers
recorded, and a documented refusal rate. If latency misses budget → streaming
mitigations, then rules-only light-touch, then MLX contingency (which reimposes
Xcode). If refusals are common on ordinary speech, Apple's model is unfit for
full-rewrite mode and that mode moves to the contingency engine. **Decide this
before any pipeline code exists.**

**M2 — Hotkey + audio.** Two-gesture state machine with an explicit timed
diagram. The first press cannot know whether it is a hold or half a double-tap —
solved by a **continuous preroll ring buffer** so no speech onset is clipped.
Ignore autorepeat. Terminate recording on tap disablement, sleep, screen lock,
permission loss, audio-route change, or max duration. Menu-bar emergency stop.
**Acceptance:** both gestures on both keys produce correct-length audio; no
stuck-mic state survives lid-close or a yanked Bluetooth mic.

**M3 — ASR.** `SpeechTranscriber` + `SpeechAnalyzer` behind `ASREngine`.
Verified available with `en-US` installed, so there is no download, no checksum,
and no cold-compile state to manage. Still required: check
`SpeechTranscriber.installedLocales` at launch and surface a clear error if the
user's locale is supported but not installed. Feed audio via the ring buffer
from M2 — do not accumulate an unbounded `[Float]`.
**Acceptance:** spoken sentence → correct transcript with a timing breakdown;
behaves correctly with wifi off.

**M4 — Insertion (buffered, non-streaming).** Capability probe, AX path, paste
fallback, secure-field rejection. Test in TextEdit, Chrome, VS Code, Terminal,
and Slack — **never synthesize Return**, and strip trailing newlines bound for a
terminal. **Acceptance:** text lands correctly in all five; undo behavior noted
per app.

**M5 — Cleanup + streaming.** Both mode prompts, per-mode cached KV prefix keyed
by a hash of model + template + prompt + dictionary. Prefix validation, sentence
segmentation, abort guards, session cancellation. Full-rewrite buffers whole.
**Acceptance:** light-touch streams sentence-by-sentence; clicking away
mid-stream aborts without corrupting the document; the app never aborts on its
own paste.

**M6 — Dictionary, settings, menu bar.** Alias map, settings UI, full lifecycle
states, launch-at-login. **Acceptance:** a previously-wrong word comes out right;
no false substitutions on a regression list.

**M7 — In-app diagnostics.** `DiagnosticsView` runs inside the signed bundle
(a CLI cannot — it has a different TCC identity, the exact trap M0 exists to
avoid). Checks permissions, model integrity, mic, ASR on a fixture WAV, cleanup
round-trip, insertion into an **app-owned scratch field**, and end-to-end latency
against budget. Also runs a small **regression corpus** asserting light-touch
invariants — content words, numbers, negation, and names preserved — with
deterministic sampling. Writes results to a log and prints `ALL CHECKS PASS`.

**M8 — Open-source release.** Only after M7 passes.

- `LICENSE` (MIT), `README.md`, `BUILDING.md`, `.gitignore`.
- **`BUILDING.md` must document the self-signed certificate step.** The plan's
  signing strategy is deliberately local-only, so every user creates their own
  cert — without instructions they will hit the silent TCC-drop trap from M0 and
  conclude the app is broken.
- **Never commit model weights.** ~1.6 GB, and acquisition is an install-time
  step by design. `.gitignore` must cover the model cache, `.build/`, the
  assembled `.app`, and any local certificate material.
- README credits section per CC-BY-4.0 (see licensing discipline above).
- Publish `scope.md`, `research.md`, and `PLAN.md` as design docs. Keep
  `PLAN-REVIEW-LOG.md` private.
- Describe the app as a local alternative to Wispr Flow. Do **not** use their
  name in the app name, icon, or branding, and do not copy their assets.
- **Repo hygiene before first push:** the working directory is currently
  `whisper copy` — the space breaks build tooling and is a poor repo name.
  Rename to something like `flowlocal` before `git init`.

**Acceptance:** a fresh clone into a clean directory builds and reaches
`ALL CHECKS PASS` by following `BUILDING.md` alone, with no undocumented steps.

---

## Verification

```bash
make doctor
```

Launches the signed app with `--diagnostics`, which runs the in-app checks under
the app's own TCC identity and tails the result log. Ends with `ALL CHECKS PASS`
or a specific failure. This is the `/goal` completion condition.

Manual acceptance:

1. Hold key 1, say *"um so the thing is uh we should ship it monday"* → light
   mode inserts `So the thing is, we should ship it Monday.` — cleaned, not reworded.
2. Double-tap key 2, dictate a rambling paragraph, double-tap to stop → full
   rewrite produces structured prose, inserted once.
3. Repeat in Chrome, VS Code, and Terminal.
4. **Wifi off**, repeat step 1 — identical behavior.
5. Revoke Accessibility mid-session → app notifies, transcript reaches the
   clipboard, nothing is lost.
6. Click into another app mid-stream → clean abort, partial text left intact.

---

## Non-goals (v1)

iOS or sync; any cloud, account, or telemetry; languages beyond English;
auto-segment; meeting recording. Per-app tone profiles and transcript history
are deferred but not architecturally precluded.

Documented limitations rather than v1 features: perfect pasteboard restoration
(impossible with promised data), multi-machine distribution (the certificate is
local-only), and model-version migration.

---

## Risks carried into the build

1. **Streaming insertion remains the fragile part**, even sentence-scoped. The
   whole-buffer paste path is the safety net, and full-rewrite already uses it.
2. **Base M1 headroom.** Every benchmark in the research came from faster
   silicon. M1 exists to replace estimates with measurements *before* the
   architecture is committed. Fallback: rules-only light-touch.
3. **Unified memory.** Apple's ~3B model plus the speech models plus Chrome all
   share 16 GB. The OS manages residency now, which removes our control as well
   as our burden — measure peak in M1 rather than assuming Apple handles it
   gracefully on the smallest supported chip.
4. **Iteration speed.** Hello-world took 69 s to compile on the old toolchain;
   the Apple-framework spikes took ~36 s on CLT 26.5.
5. **New: dependency on Apple Intelligence.** The cleanup half of the product now
   rests on a feature the user can toggle off, that Apple can change between OS
   releases, and whose guardrails can refuse input. This is the price of deleting
   the model-management subsystem. The `CleanupEngine` protocol and the retained
   MLX contingency are the hedge — do not let Apple-specific types leak past the
   protocol boundary, or the hedge stops working.

---

## Recommended `/goal` condition

`/goal` keeps working turn after turn until a small evaluator model judges the
condition met. The evaluator reads **what this session surfaces in the
conversation** — it does not run commands itself — so the condition is phrased
around output you must print.

```
/goal "make doctor has printed ALL CHECKS PASS in this conversation, and every must-have feature has been demonstrated: hotkey-to-insertion in at least three different apps, both cleanup modes, custom dictionary substitution, and an offline run with wifi off"
```

Keep it to one measurable end state plus how to prove it. `/goal` needs Claude
Code v2.1.139+, an accepted workspace-trust dialog, and hooks enabled; it
auto-resumes across `--continue`/`--resume`, so a long build can span sessions.

**If M1 fails**, do not grind against the goal condition. Stop, report the
measurements, and get a decision on the contingency path — it changes the
architecture and reimposes Xcode.
