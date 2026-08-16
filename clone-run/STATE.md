# cloneify run state

- **Target:** Wispr Flow, 100% local, macOS (slug: `whisperflow`)
- **App name:** FlowLocal
- **Run root:** `~/Developer/flowlocal` — moved out of `~/Documents` on
  2026-08-16 because iCloud Drive breaks code signing (see M0 notes)
- **Release:** public GitHub repo, **MIT**, source-only distribution

## Machine (re-verified 2026-08-15, post-upgrade)

| | |
|---|---|
| OS | macOS **26.6.1** (Tahoe), build 25G76 |
| Chip / RAM | Apple M1 base, 16 GB |
| Toolchain | Command Line Tools **26.5**, SDK 26.5, Swift **6.3.3** |
| Xcode | Not installed — **and not needed** on the primary path |
| Signing identities | 0 — self-signed cert still required (M0) |
| Apple Intelligence | **ON**, model downloaded and warm |

## ✅ Status: M0 COMPLETE. Ready for M2 (hotkey + audio).

Apple Intelligence is on, the model downloaded (~14 min), and latency is
measured. **The Apple-native path passes the budget** — short dictation is
577 ms median first-token, 8/8 under 1.5 s.

**Light-touch decision: RESOLVED — stays on the LLM.** `GenerationOptions(sampling:
.greedy)` plus a preservation-naming prompt gives deterministic, content-faithful
output at **705 ms median first-token / 947 ms total** — greedy is marginally
*faster* than default sampling, so determinism is free. The earlier "drops words,
non-deterministic" finding was default random sampling; the earlier 4–15 s
latency was machine load of 52.

**Next human-gated step: M0** — signing certificate (`sudo`) and the one-time
Accessibility + Microphone grants. macOS requires a human for TCC; this cannot
be automated or run overnight.

## What the upgrade settled (measured, not predicted)

| Question | Answer |
|---|---|
| Does CLT 26.5 expose `FoundationModels`? | **Yes** — compiles, links, resolves at runtime |
| Does `SpeechTranscriber` work? | **Yes, fully** — 30 locales supported, 9 installed, `en-US` among them |
| Does ASR need Apple Intelligence? | **No** — verified working with it off |
| Does cleanup need Apple Intelligence? | **Yes** — the one blocker |
| Is Xcode still required? | **No**, unless M1 forces the MLX contingency |

**Cut from the build:** Parakeet, FluidAudio, `ModelStore`, model downloads,
checksums, atomic staging, version migration (~1.6 GB of assets and an entire
subsystem). The OS owns model lifecycle now.

**New risk taken on:** the cleanup half depends on a user-toggleable Apple
feature whose guardrails can refuse input. M1 must probe refusal behavior, not
just latency.

## Progress

| Phase | Status | Date | Note |
|---|---|---|---|
| 0 · Scope | ✅ complete | 2026-08-15 | `scope.md` — unaffected by the upgrade |
| 1 · Research | ✅ current | 2026-08-15 | `research.md` revised: §0 remeasured, §6 resolved, landmines 1 & 5 restated |
| 2 · Plan | ✅ current | 2026-08-15 | `PLAN.md` revised: Apple-native primary, MLX demoted to contingency, M0/M1/M3 rewritten |
| 3 · Handoff | ⬜ pending | — | `GOAL-PROMPT.md` regenerates once M1 settles latency + refusal behavior |

## Resume checklist

1. ~~Enable Apple Intelligence~~ — done, model warm.
2. ~~Measure cleanup latency~~ — done, passes. See `research.md` Spike 3.
3. ~~Decide the light-touch question~~ — done, LLM + greedy sampling.
4. Run M0 (signed bundle, self-signed cert — **needs the user's password**).
5. Finish M1 inside the release bundle: peak memory, wifi-off, guardrail refusal
   probing. Latency need only be re-confirmed, not re-derived.
6. Regenerate `GOAL-PROMPT.md` with the light-touch decision baked in, then hand off.

## Blockers found and resolved during the run

1. **MLX Swift cannot build without Xcode** (Metal shader compiler) — **now
   moot** on the primary path; MLX is contingency-only.
2. **Qwen3 emits `<think>` blocks by default** — moot unless the contingency is
   triggered; documented in `PLAN.md`.
3. **Streamed text cannot be un-committed** once in another app's document.
   Resolved: sentence-level validated commits; full-rewrite buffers whole;
   remainder-only fallback. **Unaffected by the engine swap.**
4. **`kAXSecureTextFieldRole` does not exist** — secure fields are identified by
   subrole. Would have been a compile error.
5. **Mac App Store shipped an Xcode requiring macOS 26.2** — moot after the
   upgrade, and moot again because Xcode isn't needed.
6. **`softwareupdate` wedged installing CLT 26.6** — stalled at 159 MB with 0
   bytes in 90 s while the connection measured 2.7 MB/s. `/Library/Updates` is
   SIP-protected so it can't be cleared by hand. Resolved by the GUI installer
   (`Install Command Line Developer Tools.app`), which delivered CLT 26.5 in
   16 minutes.

## Open-source decisions (locked 2026-08-15)

- **License: MIT.** **VoiceInk is GPL-3.0 — its code must not be copied.**
  Reading for technique only. *(Note: with Parakeet/FluidAudio cut, the
  remaining third-party dependency surface is near zero — the CC-BY-4.0
  attribution requirement for Parakeet no longer applies unless the contingency
  is triggered.)*
- **Distribution: source-only.** `BUILDING.md` must document the self-signed
  cert step, and now also that **Apple Intelligence must be enabled** — without
  it the app builds and runs but cleanup silently degrades.
- **Docs published:** `scope.md`, `research.md`, `PLAN.md`.
  `PLAN-REVIEW-LOG.md` stays private.
- Rename the working directory (currently `whisper copy` — the space breaks
  build tooling) before `git init`.

## Deviations from the cloneify skill

`deep-research` and `grill-me-codex` are **not installed** — only `cloneify`
came over from Downloads. Phase 1 ran inline with web search plus local
verification spikes; Phase 2 ran as an inline interview plus four `codex exec`
rounds via `~/.local/bin/codex` (read-only sandbox, in-terminal, per the user's
request). Install those skills before the next run.

---

## Scaffolding built 2026-08-16 (no permissions required)

**Builds clean. 17/17 tests pass. Bundle assembles.**

| File | Purpose |
|---|---|
| `Package.swift` | `FlowLocalCore` (lib, testable) + `FlowLocal` (exe) + tests |
| `Sources/FlowLocalCore/CleanupMode.swift` | Modes, streaming eligibility, per-mode timeouts |
| `Sources/FlowLocalCore/CleanupEngine.swift` | Provider-agnostic protocol + `UnavailableCleanupEngine` |
| `Sources/FlowLocalCore/AppleCleanupEngine.swift` | **Measured config baked in**: fresh session per dictation, `sampling: .greedy`, watchdog timeout, refusal classification |
| `Sources/FlowLocalCore/ASREngine.swift` | Protocol + `AudioChunk` (stream, not unbounded `[Float]`) |
| `Sources/FlowLocalCore/VocabularyMatcher.swift` | Phrase aliases, whole-token, protected tokens |
| `Sources/FlowLocalCore/Permissions.swift` | Read-only checks; never prompts |
| `Sources/FlowLocal/main.swift` | `--diagnostics`, prints `ALL CHECKS PASS` |
| `Tests/FlowLocalCoreTests/` | 17 Swift Testing cases |
| `build/Info.plist` | `LSUIElement`, stable bundle ID `dev.kilanii.flowlocal` |
| `Makefile` | `build test bundle sign doctor cert-help clean` |

### Two toolchain findings worth keeping

1. **XCTest does not exist in Command Line Tools** — it ships with Xcode. Use
   Swift Testing (`import Testing`).
2. **Swift Testing needs manual paths under CLT.** `Testing.framework` and
   `lib_TestingInterop.dylib` live in two *different* CLT directories and SwiftPM
   adds neither. Requires `-F` plus **two** `-rpath` flags or the test bundle
   fails to `dlopen`. Encoded in the Makefile `test` target.

### Two real bugs the tests caught (already fixed)

- All-caps words ("SWIFT") were wrongly protected as identifiers. Fixed: require
  *both* cases present before treating an interior capital as code.
- `.` was a word character, so "swift." swallowed its period and alias lookup
  missed. Fixed: `.` and `:` join words only *between* alphanumerics.

## ⚠️ NEXT SESSION — read this before trusting the diagnostics

`make doctor` currently prints `ALL CHECKS PASS`, **and the permission lines in
it are not yet meaningful.** The binary was run from a shell, so
`AXIsProcessTrusted()` inherited the *terminal's* Accessibility grant — the exact
trap documented in `research.md`. The bundle is also **unsigned**; `make sign`
has never run because no signing identity exists yet.

M0 remains genuinely outstanding:

1. `make cert-help` → create the self-signed cert in Keychain Access (GUI, ~2 min)
2. `make sign` → verify `codesign -dvvv --strict` is clean
3. Launch the signed `.app` from Finder (not the shell), grant Accessibility +
   Microphone when prompted
4. Rebuild 3× and confirm the grants survive — that is M0's real acceptance test
5. Then finish M1 in-bundle: peak memory, wifi-off, guardrail refusal probing


---

## M0 COMPLETE — 2026-08-16

**Acceptance met:** permissions granted once, survived **three consecutive
rebuilds**, `ALL CHECKS PASS` each time. Verified from a Finder-launched signed
bundle under its own TCC identity — not a terminal child.

```
[PASS] running from an app bundle      [PASS] accessibility
[PASS] microphone — authorized         [PASS] FoundationModels available
[PASS] phrase substitution + protection
```

### Four blockers hit, all non-obvious, all now encoded in the Makefile

1. **iCloud Drive makes `codesign --verify --strict` impossible.** The project
   was in `~/Documents`, which is iCloud-synced. `fileproviderd` re-adds
   `com.apple.FinderInfo` to the bundle faster than `xattr -cr` strips it, so
   verification always failed with "resource fork, Finder information, or similar
   detritus not allowed". **Fixed by moving the project to `~/Developer/flowlocal`.**
   This also stopped `.build` from syncing to iCloud on every compile — which was
   a major source of the machine load that corrupted the Spike 3 benchmarks.

2. **The hardened runtime denies the microphone SILENTLY.** Signing with
   `--options runtime` without `com.apple.security.device.audio-input` produces
   no TCC prompt at all: status stays `notDetermined`, `requestAccess` returns
   false immediately, and `AVAudioEngine` starts successfully and delivers
   silence. It looks exactly like a bug in your own code. Fixed with
   `build/FlowLocal.entitlements`.

3. **AMFI rejects XML comments in an entitlements file** —
   "AMFIUnserializeXML: syntax error". Keep that file comment-free; document
   elsewhere.

4. **TCC dialogs need `NSApplication` initialized.** Without
   `NSApplication.shared` + an activation policy + a pumped run loop, the prompt
   never renders.

Plus two smaller ones: `find-identity -v` shows **zero** identities for a
self-signed cert (trust governs *verification*, not signing — sign anyway, do not
add trust), and Swift 6 rejects `kAXTrustedCheckOptionPrompt` as concurrency-unsafe
(use the `"AXTrustedCheckOptionPrompt"` literal).

### Certificate

`make cert` runs `build/make-cert.sh`, which creates the self-signed identity via
openssl + `security import`. Two gotchas encoded there: `security import`
mishandles an empty PKCS12 password (use a throwaway one), and LibreSSL 3.3.6 is
what `/usr/bin/openssl` actually is.

## Next: M2 — hotkey + audio capture

M1 is substantially done (latency measured, engine available in-bundle).
Outstanding from M1: peak memory with `SpeechTranscriber` active, wifi-off
verification, and guardrail refusal probing — all now runnable inside the signed
bundle.

---

## M1 COMPLETE — verdict: LLM light-touch REJECTED (2026-08-16)

**The Apple-native cleanup path failed the latency requirement.** Measured inside
the signed bundle on an idle machine, 10-item corpus:

```
latency  median 7168 ms | min 4296 | max 8432
under 1500 ms: 0/10        peak footprint: 9.1 MB
```

**The earlier "705 ms, passes budget" figure was an artifact** — that benchmark
repeated a *single* input four times and took the median. Repeated input
converges to ~990 ms; novel input (what dictation actually is) runs 4–8 s.
Ruled out as causes: prompt length (20w vs 85w both ~7 s), bundle vs terminal
(both ~7 s), machine load (idle, 2.7). Behavior is bimodal and unexplained —
~700 ms when fresh, ~7 s under sustained use, on a MacBookPro17,1.

**Worse than slow — silently lossy.** 2 of 10 items lost content with
`refusals: 0/10`, i.e. no error raised:

| input | output |
|---|---|
| "...nda is unenforceable and we should countersue for damages" | `"Our counsel says the NDA is unenforceable and"` (truncated) |
| "the patch completely killed performance and murdered our latency budget" | `""` (empty) |

Greedy sampling did not prevent this.

### Decision: light-touch is rules-based; LLM only for full rewrite

| | engine | measured |
|---|---|---|
| Light-touch | `RulesCleanup` | **0.26 ms median**, deterministic, no network |
| Full rewrite | `FoundationModels` behind a content-loss guard | ~7 s, acceptable — the user explicitly asked for a rewrite |

Both previously-failing corpus items now return **complete** text via rules.

**New files:** `RulesCleanup.swift`, `RoutingCleanupEngine.swift`,
`RulesCleanupTests.swift`. **39/39 tests pass.** `Package.swift` now exposes
`FlowLocalCore` as a library product.

`RoutingCleanupEngine.contentLoss` rejects empty output, loss below 25% of input
words, and clauses ending on a dangling conjunction — the exact observed
truncation signature. On rejection the pipeline falls back to the raw transcript.

### Known gaps in rules light-touch (document in README)

- No self-correction resolution ("Monday, no actually Tuesday"). **The model
  could not do this either**, even given an explicit rule and a worked example.
- No contraction repair (`wasnt` → `wasn't`). Closed set; safe to add later.
- No proper-noun capitalization beyond days/months — that is the user
  vocabulary's job.
- Does not invent sentence boundaries; a long run-on stays a run-on.

## M2 in progress

`AudioRingBuffer.swift` (lock-free SPSC, continuous preroll for the
hold-vs-double-tap ambiguity) and `HotkeyGesture.swift` (pure two-gesture state
machine) are written. **Not yet tested or wired to Core Audio / CGEventTap.**
