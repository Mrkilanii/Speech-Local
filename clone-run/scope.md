# Scope — a local dictation app

## Target

**Wispr Flow** (wisprflow.ai) — hotkey-triggered dictation for macOS. Press a
global hotkey anywhere, speak, release; the app transcribes the audio, runs an
AI cleanup pass over the raw transcript, and inserts the polished text at the
cursor in whatever app has focus.

The reason to build rather than subscribe: Wispr Flow sends audio to the cloud
and costs a monthly fee. This build does the same job entirely on-device.

## Platform

macOS, Apple Silicon. No other platform in v1.

## Must-have features

1. **Hotkey → speak → auto-type.** Global hotkey captured system-wide; audio
   recorded while held (or between press/press); on release the transcript is
   inserted at the cursor in the frontmost app. This is the core loop — nothing
   else matters if this doesn't feel instant and reliable.
2. **Local AI cleanup pass.** An on-device LLM rewrites the raw transcript:
   strips disfluencies ("um", restarts), fixes punctuation and casing, applies
   light formatting. This is the difference between this and plain dictation.
3. **Custom dictionary / vocabulary.** User-supplied names, jargon, and acronyms
   bias the output so proper nouns survive transcription.
4. **Menu bar app + settings UI.** Status item reflecting idle / recording /
   processing, plus a preferences window for hotkey, model selection, and mic
   input device.

## Hard constraints (non-negotiable)

- **100% local.** No network calls at runtime for any core function. No cloud
  transcription, no cloud LLM, no fallback path that phones home. Model
  downloads at install/setup time are the only permitted network use.
- **No account, no subscription, no telemetry.**
- **Snappy.** Text lands within ~1.5s of hotkey release for a normal sentence.
  This bounds model choice: small/distil-class ASR (Whisper small/distil or
  Parakeet) plus a 1–4B cleanup model, not the big ones.
- **Runs as a real .app** the user can keep in the menu bar across reboots.

## Stack

Native **Swift / SwiftUI**:

- AppKit menu-bar item (`NSStatusItem`) + SwiftUI settings window.
- Global hotkey via event tap / `NSEvent` global monitor.
- Text insertion via macOS Accessibility APIs (`AXUIElement`) with a
  pasteboard + synthesized ⌘V fallback.
- ASR: WhisperKit (CoreML) or whisper.cpp — to be decided in research/planning.
- Cleanup LLM: MLX Swift (or llama.cpp) running a small local model.

Chosen because the core loop lives in native macOS territory — event taps,
Accessibility, audio capture, and low-latency inference. A scripting stack would
fight all four.

## Out of scope (v1)

**Explicitly ruled out:**

- iOS/iPadOS companion app; any cross-device sync.
- Any cloud service, user account, login, server component, or analytics /
  telemetry of any kind.

**Deferred — not in v1, but the design should not preclude them:**

- Per-app tone profiles (Slack voice vs. email voice) and voice command mode
  ("make that a bullet list").
- Transcript history / searchable archive of past dictations.
