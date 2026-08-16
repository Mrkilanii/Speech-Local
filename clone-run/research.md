# Research — a local dictation app for macOS

Phase 1 output. Sources listed at the bottom. Machine-specific findings were
verified locally on this Mac, not taken from the web.

---

## 0. This machine (verified locally)

> **Updated 2026-08-15, after the macOS 26 upgrade.** The original Sequoia
> findings are superseded; §6 is now resolved rather than open.

| Fact | Value | Why it matters |
|---|---|---|
| Chip | **Apple M1 (base)** — 8 GPU cores | ~⅓ to ¼ the inference throughput of the M1 Max numbers most benchmarks quote. Every published tok/s figure must be discounted hard. |
| RAM | **16 GB** unified | Comfortable for OS-managed ASR + a 3B LLM. Rules out anything 7B+ running hot alongside a browser. |
| macOS | **26.6.1 (Tahoe)**, build 25G76 | **Unlocks `SpeechTranscriber` and `FoundationModels`.** Resolves the plan's biggest fork — see §6. |
| Toolchain | **Command Line Tools 26.5**, SDK 26.5, **Swift 6.3.3**, target `arm64-apple-macosx26.0` | Installed via the GUI installer after `softwareupdate` wedged. No Xcode. |
| Xcode | **Not installed, and not needed** on the Apple-native path | MLX's Metal shaders were the *only* thing that required it. `metal` is still absent from CLT and always will be — it ships with Xcode. Xcode returns as a requirement only if M1 forces the MLX fallback. |
| Codesigning identities | **0 valid** | A self-signed cert must be created during setup, or permissions break on every rebuild (§5, landmine 2). Unchanged by the upgrade. |
| Apple Intelligence | **ON**, model downloaded (~14 min @ 4.4 MB/s) | `FoundationModels` available and measured — see Spike 3. |

### Spike 2: do the Apple-native frameworks actually work here? (2026-08-15)

Both compiled against the CLT 26.5 SDK with **no Xcode** — `import
FoundationModels`, `import Speech`, `SystemLanguageModel`,
`LanguageModelSession`, `streamResponse`, `SpeechTranscriber`. Builds took
~36 s each. Then, at runtime:

| Framework | Result |
|---|---|
| **`SpeechTranscriber`** | ✅ **Working now, no Apple Intelligence required.** 30 supported locales; **9 already installed** (`en_US`, `en_GB`, `en_CA`, `en_AU`, `en_IE`, `en_NZ`, `en_ZA`, `en_IN`, `en_SG`). `en-US` supported **and installed** — zero model download. |
| **`FoundationModels`** | ⚠️ Compiles and resolves, but returns `unavailable(appleIntelligenceNotEnabled)`. Needs the Settings toggle plus Apple's model download. |

**Consequence:** the ASR subsystem collapses to an OS call. Parakeet
(~600 MB), FluidAudio, and the whole model-download/checksum/staging layer are
**no longer needed**. The cleanup half is gated on a toggle, not on engineering.

### Spike 3: `FoundationModels` latency on this M1 — MEASURED (2026-08-16)

Apple Intelligence enabled; model downloaded in ~14 min at ~4.4 MB/s. All runs
are debug builds from a terminal, machine load ~3–6 (not fully idle).

**Short utterances (8–13 words) — the common case:**

| Session strategy | median first-token | max | under 1.5 s budget |
|---|---|---|---|
| **Fresh session per dictation** | **577 ms** | **659 ms** | **8/8** ✅ |
| One reused session | 701 ms | 3826 ms | 5/8 ❌ |

**The counterintuitive result: reusing a session is worse.** A reused
`LanguageModelSession` accumulates conversation history, so prefill grows every
turn and periodically spikes to 3.5–3.8 s. Creating a **fresh session per
dictation** is faster, far more consistent, *and* semantically correct — no
cross-contamination between dictations, no context-limit growth. The obvious
optimization is a pessimization here.

**Long utterance (~70 words), fresh session, three consecutive runs:**

| Run | first-token | first-sentence | total | decode |
|---|---|---|---|---|
| 1 | 6928 ms | 10818 ms | 11674 ms | 5.0 w/s |
| 2 | 3759 ms | 5122 ms | 5491 ms | 10.7 w/s |
| 3 | **718 ms** | **1618 ms** | 2444 ms | 23.7 w/s |

Same input, 4.8× spread. Performance **improves markedly across consecutive
runs**, so the model keeps warming well past the first call — a single
`prewarm()` plus one warm-up request is not enough to reach steady state.

**Cold first-ever invocation: 13.5 s.** Must never sit in the user's path.

**Verdict:** short dictation passes the budget comfortably. Long dictation is
viable *only* with streaming, and its tail is bad enough to need a timeout with
a documented fallback. The variance — not the median — is the engineering
problem.

**Quality (separate from latency, and less good):**

> **CORRECTION (later the same session):** the non-determinism below was an
> artifact of **default (random) sampling**, not a property of the model.
> `GenerationOptions(sampling: .greedy)` or `temperature: 0.0` produced
> **identical output across every repeated run**. And a prompt that explicitly
> names what to preserve fixed the content loss: hedges (`I think`), discourse
> markers (`So`, `well`, `you know`), and casual forms (`gonna`) were all kept,
> with `thats` → `that's` corrected. Both problems below are solved.
>
> **What no prompt fixed: self-correction.** `"lets move the standup to monday
> no actually tuesday"` returned `"...to Monday, no actually Tuesday."` — the
> correction was not applied, despite an explicit rule *and* a few-shot example
> demonstrating exactly that transformation. This is Wispr Flow's signature
> behavior, and Apple's model does not do it. Rules can't either, so it is not a
> discriminator between the two approaches — it is a v1 limitation to document.
>
> **Latency of greedy sampling: MEASURED on an idle machine (load 2.68).**
> Greedy is **free** — median first-token 705 ms vs 742 ms for default, with a
> tighter max (705 vs 770 ms). Total ~947 ms, well inside the 1.5 s budget.
> `temperature: 0.0` performs identically. **Determinism costs nothing.**
>
> The 4–15 s readings that prompted this correction were pure machine load
> (Spotlight reindexing + iCloud resync + a user `npm test`, load 52). Under
> load the *same* configuration is 10× slower. Any future benchmark must check
> load first or it will produce fiction.


Superseded observations, kept for the record:

- Long-form preserves content well: 70 → 58 words, fillers dropped, hedges like
  "you know" and "that's my take" kept.
- **Short-form is non-deterministic and lossy.** The same input produced
  `"The thing is, we should ship it Monday."`, `"...Monday, I think."`,
  `"So, the thing is..."`, and `"...ship it on Monday."` across four runs —
  dropping `"I think"`, dropping `"So"`, and once **inserting a word that was
  never spoken** ("on"). Filler removal is inconsistent; one run kept a leading
  "Uh,".
- This is exactly what the plan's M7 regression corpus exists to catch, and it
  argues for rules-based handling of the light-touch path rather than trusting
  the model to "only fix punctuation."

### Spike 1: can we build a SwiftUI menu-bar app without Xcode?

**Yes.** A minimal SPM executable importing `SwiftUI`, `AppKit`, `AVFoundation`,
`CoreML`, and `ApplicationServices` compiled and linked cleanly against the CLT
SDK (MacOSX.sdk 15.5). Cold build: **69s**. All required frameworks are present
in the CLT SDK.

Two things the spike also proved, both of which shape the build:

1. **Running the bare SPM binary crashes on `NSStatusBar`** with
   `Assertion failed: (CGAtomicGet(&is_initialized)), CGSConnectionByID`. A
   menu-bar app needs a real `.app` bundle (`Info.plist`, `LSUIElement`, proper
   bundle ID) with a WindowServer connection. The build system must assemble the
   bundle by hand — `swift build` alone is not enough.
2. **`AXIsProcessTrusted()` returned `true`** for the CLI — inherited from the
   terminal's own Accessibility grant. This is a *trap*: dev-from-terminal will
   look permitted while the packaged `.app` is not. Test permissions only via
   the bundle.

---

## 1. What Wispr Flow actually is

Hotkey-triggered, system-wide dictation. Press a hotkey anywhere, speak, release;
polished text appears at the cursor in whatever app has focus — Gmail, Slack,
VS Code, a random web form. Users report sustaining 150–180 wpm.

The product is not "speech to text." It's **speech to *finished* text**. The
cleanup layer is the whole value proposition: if you correct yourself mid-
sentence, only the corrected version is emitted. That is what separates it from
macOS's built-in dictation, and it's the part a clone must get right.

### Full feature inventory (the original)

| Feature | In our v1? |
|---|---|
| Hotkey → speak → insert at cursor, any app | ✅ must-have |
| AI cleanup: disfluencies, punctuation, self-corrections | ✅ must-have |
| Custom dictionary (names, jargon, acronyms) | ✅ must-have |
| Menu bar presence + settings | ✅ must-have |
| Command Mode — select text, speak an instruction, AI rewrites it | ⏸ deferred |
| Per-app tone profiles (Slack voice ≠ email voice) | ⏸ deferred |
| Auto-segment — detects natural pauses, auto-submits short replies | ❌ not scoped |
| 100+ languages | ❌ not scoped (English v1) |
| Meeting recorder / Notetaker (shipped Aug 2026) | ❌ out of scope |
| iOS app, cross-device sync | ❌ ruled out |

**The original is cloud-based.** Its transcription and formatting run on remote
models. So there is no local-architecture blueprint to copy — the clone has to
solve on-device latency itself, which is the whole engineering problem.

---

## 2. Prior art worth reading before writing code

| Project | Stack | License | Take |
|---|---|---|---|
| **VoiceInk** | Swift, whisper.cpp XCFramework | GPL-3.0 | **The closest reference.** ~4.3k stars, actively maintained (v1.72, Mar 2026). Native Swift, local Whisper + Parakeet, system-wide insertion, "Power Mode" for per-app config. Read its source for insertion and hotkey handling. Caveat: GPL-3.0 — copying code means our app is GPL too. Read for *technique*, don't paste. Its Makefile also builds whisper.cpp as an XCFramework, which is a useful pattern. |
| **Handy** | Rust/Tauri, cross-platform | MIT | Genuinely free, fully local, finished. Permissive license. Different stack, so it's a design reference, not a code source. |
| **OpenWhispr** | Electron, Whisper + Parakeet | OSS | Cross-platform, local-or-BYOK-cloud. Electron — exactly the architecture we rejected. |
| **Yap** | Swift, Apple Speech framework | OSS | **Directly relevant to the macOS 26 question.** On-device dictation with *no model download at all* because it uses Apple's built-in Speech framework. Proof the OS-native path works. |
| **megaphone** | Swift, SpeechAnalyzer + FoundationModels | OSS | The macOS 26 path end-to-end: Apple's ASR *and* Apple's on-device LLM for cleanup. If we upgrade macOS, this is the architecture. |
| **superwhisper** | closed | paid | Best-in-class commercial local competitor. Benchmark for UX, not a source. |

The existence of Yap and megaphone is the strongest argument for the macOS 26
decision in §6.

---

## 3. Technical approach — ASR

| Option | Runs on | Speed | Notes |
|---|---|---|---|
| **FluidAudio + Parakeet TDT 0.6B (CoreML)** | Neural Engine | ~110× RTF on M4 Pro; ~800 MB peak | Pure Swift SPM package, ANE-offloaded. Parakeet is 0.6B vs Whisper's 1.5B, non-autoregressive (no token-by-token decode), <3% WER English. **Reportedly tuned to drop fillers and reconstruct sentences** — which does part of the cleanup job for free. 25 languages. |
| **WhisperKit** | Neural Engine | ~150–300 ms | Whisper weights recompiled to CoreML. 99 languages. Slower than Parakeet; better multilingual. |
| **whisper.cpp** | Metal/GPU | slowest of the three | What VoiceInk uses. Most portable, most control, requires building an XCFramework. |
| **Apple `SpeechTranscriber`** | OS-managed | ~2× faster than Whisper large-v3-turbo | **macOS 26 only.** Zero model download, OS-managed languages, streaming built in. |

**Leaning:** Parakeet via FluidAudio on macOS 15; Apple's `SpeechTranscriber` if
we upgrade. Parakeet's non-autoregressive decode is the key property — decode
time doesn't scale with output length the way Whisper's does, which is exactly
what a latency budget needs. English-only is fine given scope.

---

## 4. Technical approach — the cleanup LLM (this is where the budget dies)

### The arithmetic, honestly

Published MLX figures: ~63 tok/s decode on a 3B 4-bit model **on an M1 Max**.
This machine is a base M1 — roughly a quarter of the GPU. Realistic estimate
here: **~20–30 tok/s for 3B, ~40–50 tok/s for 1.5B**, 4-bit.

Now price a single normal dictation — one 30-word sentence:

| Stage | Estimate |
|---|---|
| Audio finalize + VAD | ~50 ms |
| Parakeet ASR (ANE) | ~150–250 ms |
| LLM prefill (system prompt + dictionary + transcript ≈ 400–600 tok) | ~250–400 ms |
| LLM decode (~45 output tokens @ 40 tok/s) | **~1100 ms** |
| Insertion | ~30 ms |
| **Total** | **~1.6–1.8 s** |

**That misses the 1.5 s target, on the optimistic end of every estimate, for a
short sentence.** Longer dictation is worse, because decode scales linearly with
output length while the budget doesn't.

A second trap: benchmark tok/s figures usually report **decode only and exclude
prefill**. One measurement found effective throughput collapsing from a reported
51 tok/s to ~3 tok/s once prefill at long context was counted. Our prompt carries
a system instruction plus the whole custom dictionary — that's real prefill, every
single time. Quantization does not help prefill; it's FLOP-bound, not bandwidth-bound.

### Ways out (planning must pick one)

1. **Stream the cleanup output and type incrementally.** Perceived latency drops
   to first-token (~400 ms) even though total time is unchanged. Best UX-per-effort.
2. **Two-phase insert.** Drop raw ASR text instantly, then replace with the
   cleaned version. Fast, but replacement is fragile if the user moves the cursor.
3. **Shrink the cleanup model** to 0.5–1B. Faster, noticeably dumber at rewriting.
4. **Cache the prefix.** The system prompt + dictionary are constant — a cached
   KV prefix kills most prefill cost. Real, and worth doing regardless.
5. **Lean on Parakeet's native filler removal** and use rules (punctuation,
   capitalization, dictionary substitution) instead of an LLM for the common case,
   escalating to the LLM only for messy input.
6. **Apple `FoundationModels`** — macOS 26 only, but Apple-optimized and free.

Options 1 and 4 are close to mandatory. The rest is a real design choice.

---

## 5. Technical approach — text insertion

Two mechanisms, and mature apps use **both**:

- **Accessibility API** — `AXUIElementSetAttributeValue` + `kAXSelectedTextAttribute`.
  The "correct" way. Requires the app be code-signed, App Sandbox **disabled**,
  and Accessibility granted. Fails in apps that don't expose proper AX text elements.
- **Synthesized ⌘V** — put text on the pasteboard, `CGEvent.post` the keystroke.
  Works nearly everywhere, including Electron apps and terminals that ignore AX.
  Costs: clobbers the user's clipboard (must save/restore), and it's a *different*
  TCC service — `kTCCServicePostEvent` vs `kTCCServiceAccessibility` — even though
  both display under "Accessibility" in System Settings.

Consensus from the field: neither works well alone. **Try AX, fall back to paste.**
Budget real time for a per-app compatibility matrix — Electron apps, Terminal/iTerm,
and password fields (secure input) each behave differently, and secure input mode
will block synthetic events entirely by design.

---

## 6. ~~THE open decision~~ → RESOLVED: upgraded to macOS 26

**Decided and executed 2026-08-15. The machine is on Tahoe 26.6.1.** The
analysis below is kept as the reasoning; the outcome is at the end of the section.

This dominated everything else in the plan.

**Staying on macOS 15.7.4:**
- ASR: FluidAudio/Parakeet CoreML — ~600 MB model download, managed by us.
- Cleanup: MLX Swift + a 1–4B model — another ~1 GB, managed by us.
- We own model download, storage, versioning, warm-up, and memory pressure.
- Latency per §4 is **tight to failing** on this hardware.
- No dependency on Apple's release cadence or Apple Intelligence availability.

**Upgrading to macOS 26 (Tahoe):**
- ASR: `SpeechTranscriber` — **no model download**, OS-managed, streaming,
  reportedly ~2× faster than Whisper large-v3-turbo.
- Cleanup: `FoundationModels` — a ~3B on-device model Apple ships and optimizes.
  **The M1 is eligible** (Apple Intelligence requires A17 Pro / M1 or newer).
- Removes an entire subsystem: no model downloads, no MLX, no quantization
  choices, no ~1.6 GB of weights to manage. Substantially less code.
- Two working open-source references already exist (Yap, megaphone).
- Costs/risks: an OS upgrade on the user's daily machine; Apple Intelligence
  must be enabled; `FoundationModels` availability is a runtime feature flag that
  can fail and must be handled; the model has guardrails that can refuse input;
  ~4k context; first-token latency is "non-trivial" and unmeasured on a base M1.

### Outcome (measured, not predicted)

The upgrade happened, and the spikes in §0 settle most of it:

- **ASR is done.** `SpeechTranscriber` works today, `en-US` already installed,
  no Apple Intelligence needed, no download. Parakeet + FluidAudio + the entire
  `ModelStore` subsystem are **cut from the build**.
- **Xcode is not needed.** With MLX gone there are no Metal shaders to compile,
  and everything required builds against CLT 26.5. This holds *unless* the
  cleanup fallback below is triggered.
- **Cleanup is gated, not solved.** `FoundationModels` compiles and resolves but
  reports `appleIntelligenceNotEnabled`. Enabling it is a Settings toggle plus
  Apple's own model download.

**What is still unmeasured — and it is the same risk as before, just relocated:**
Apple's first-token latency for a cleanup rewrite on a *base* M1, and whether
the model's guardrails refuse ordinary dictation text. §4's arithmetic was
written for MLX; it does not transfer. Nobody has published the Apple number for
this chip, so M1 must measure it.

**Fallback if M1 fails:** drop back to MLX + a small local model — which
re-imposes the Xcode requirement and restores `ModelStore`. The protocol
abstraction exists to make that a backend swap rather than a rewrite. Do not
delete the MLX research above; it is the contingency.

---

## 7. Landmines — the five most likely to sink the build

*(Post-upgrade note: landmines 2, 3, and 4 are unaffected by the move to macOS
26 — they are about signing, bundling, and other apps' text fields. Landmines 1
and 5 are restated below.)*

1. **The 1.5 s budget vs. the cleanup pass — still #1, now with a different
   engine.** §4's MLX arithmetic no longer applies; `FoundationModels` replaces
   it, and its latency on a base M1 is **unmeasured** because Apple Intelligence
   is off. The structural risk is unchanged: cleanup generation is the only
   stage whose cost scales with output length. Streaming remains the mitigation.
   If Apple's model misses the budget, the fallback is MLX (Xcode returns) or a
   rules-only path.
2. **TCC permission loss on every rebuild.** Ad-hoc signing (`codesign -s -`)
   generates a fresh identity each build, so macOS treats each build as a new app
   and silently drops the Accessibility grant — prompts can stop appearing until
   stale entries are cleared. This machine has **0 signing identities**. Fix: create
   a stable self-signed certificate in Keychain during setup and sign every build
   with it. Adequate here because the app is for this machine only; a Developer ID
   would only matter for distribution.
3. **The bundle problem.** Verified by spike: a bare SPM binary dies on
   `NSStatusBar`. The build must assemble a genuine `.app` — `Info.plist`,
   `LSUIElement=1`, `NSMicrophoneUsageDescription`, stable bundle ID, then sign.
   And `AXIsProcessTrusted()` lies when run from the terminal (inherits the
   terminal's grant), so permission testing must go through the bundle or you'll
   chase ghosts.
4. **Insertion compatibility across apps.** §5. AX alone won't cover Electron and
   terminals; paste alone clobbers the clipboard and dies in secure input. Needs
   both paths plus a save/restore clipboard dance, and it needs testing in the
   apps actually used daily, not just TextEdit.
5. **Hardware headroom.** Base M1, 8 GPU cores, 16 GB. Every quoted benchmark in
   this document was measured on faster silicon (M1 Max, M4 Pro). Cold-start model
   load, thermal throttling on a fanless Air, and memory pressure with a browser
   open are all real. **The plan must include measuring on this machine early**,
   before architecture is locked — the spike above took 69s just to compile a
   hello-world, which is itself a signal about iteration speed.

---

## 8. Decisions planning must resolve

1. **macOS 26 upgrade — yes or no?** (§6) Everything else depends on it.
2. **Latency strategy:** streaming insert / two-phase / smaller model / rules-first?
   And is 1.5 s a hard requirement or an aspiration? (§4)
3. **Push-to-talk (hold) vs. toggle (press-once)?** Affects VAD, and whether
   streaming is even coherent.
4. **What does "custom dictionary" mean mechanically** — post-hoc string
   substitution, LLM prompt injection, or ASR-level biasing? Cheapest is
   substitution; best is biasing; prompt injection costs prefill every time (§4).
5. **Cleanup aggressiveness.** Light-touch punctuation, or full rewrite? Full
   rewrite risks the model editorializing your words — a real complaint about
   this product category.
6. **Fallback when a permission is missing or a model fails to load** — silent
   degrade to raw text, or refuse and tell the user?

---

## Sources

- [Wispr Flow review — Efficient App](https://efficient.app/apps/wispr-flow)
- [Wispr Flow review — zackproser](https://zackproser.com/blog/wisprflow-review)
- [Wispr Flow review 2026 — tldv](https://tldv.io/blog/wisprflow/)
- [VoiceInk on GitHub](https://github.com/Beingpax/VoiceInk) · [BUILDING.md](https://github.com/Beingpax/VoiceInk/blob/main/BUILDING.md)
- [Handy vs Wispr Flow — Voibe](https://www.getvoibe.com/resources/handy-vs-wispr-flow/)
- [OpenWhispr on GitHub](https://github.com/OpenWhispr/openwhispr)
- [Yap — on-device dictation, Apple Speech framework](https://github.com/FrigadeHQ/yap)
- [megaphone — SpeechAnalyzer + FoundationModels](https://github.com/Kuberwastaken/megaphone)
- [FluidAudio Swift SDK](https://github.com/FluidInference/FluidAudio) · [Parakeet TDT 0.6B CoreML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml)
- [Parakeet vs Whisper on Mac — Dictato](https://dicta.to/blog/whisper-vs-parakeet-vs-apple-speech-engine/)
- [Whisper→Parakeet on the Neural Engine — MacParakeet](https://macparakeet.com/blog/whisper-to-parakeet-neural-engine/)
- [Swift/macOS: insert text into other apps, two ways](https://levelup.gitconnected.com/swift-macos-insert-text-to-other-active-applications-two-ways-9e2d712ae293)
- [Accessibility permission in macOS — jano.dev](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)
- [Preserve macOS app permissions across rebuilds with self-signed certificates](https://evoleinik.com/posts/macos-dev-signing-preserve-permissions/)
- [SpeechAnalyzer vs SFSpeechRecognizer](https://blakecrosley.com/blog/speech-framework-vs-sfspeechrecognizer) · [WWDC25: SpeechAnalyzer](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Exploring the Foundation Models framework](https://www.createwithswift.com/exploring-the-foundation-models-framework/) · [Limitations & capabilities](https://www.natashatherobot.com/p/apple-foundation-models)
- [Apple Silicon LLM benchmarks M1–M5](https://llmcheck.net/benchmarks) · [MLX inference optimization](https://branch8.com/posts/apple-silicon-mlx-llm-inference-optimization-tutorial)
