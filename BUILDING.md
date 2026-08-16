# Building SpeechLocal

Four commands, but **step 2 is not optional** — skip it and macOS silently
revokes your permissions on every rebuild, leaving an app that launches fine and
does nothing.

## Requirements

- macOS 26 (Tahoe) or later, Apple Silicon
- **Command Line Tools** — full Xcode is not needed:
  ```bash
  xcode-select --install
  ```
- Apple Intelligence enabled (System Settings → Apple Intelligence & Siri) —
  required only for full-rewrite mode

## 1. Clone and test

```bash
git clone https://github.com/Mrkilanii/Speech-Local.git
cd Speech-Local
make test
```

**Do not put the repo inside iCloud Drive** (`~/Documents` or `~/Desktop` if
Desktop & Documents syncing is on). `fileproviderd` re-adds
`com.apple.FinderInfo` to the app bundle faster than the build can strip it, and
`codesign --verify --strict` then fails forever with *"resource fork, Finder
information, or similar detritus not allowed"*. It also syncs your `.build`
directory on every compile. `~/Developer` is a good home.

## 2. Create a signing certificate

```bash
make cert
```

This creates a self-signed code-signing identity called `SpeechLocal Dev` in your
login keychain.

**Why this matters.** macOS ties permission grants to an app's code signature.
Ad-hoc signing (`codesign -s -`) mints a *new* identity on every build, so each
rebuild looks like a brand-new app: your Accessibility grant is dropped, and
macOS stops prompting for it. The app runs, sees no permissions, and does
nothing. A stable identity fixes this permanently.

Self-signed is sufficient because distribution is source-only — every user
builds and signs locally. A Developer ID would only matter for shipping binaries.

> `security find-identity -v -p codesigning` will report **zero** identities even
> after this succeeds. That is expected: `-v` filters to *trusted* certificates,
> and a self-signed root is untrusted. Trust governs signature *verification*,
> not signing. Do not "fix" it by adding trust — it triggers an admin prompt and
> buys nothing.

## 3. Build and sign

```bash
make sign
```

Produces `dist/SpeechLocal.app`, verified with `codesign --verify --strict`.

## 4. Grant permissions

Launch **from Finder**, not the terminal:

```bash
open dist/SpeechLocal.app --args --request-permissions
```

Approve both prompts. If Accessibility does not appear in the list, add
`dist/SpeechLocal.app` manually under System Settings → Privacy & Security →
Accessibility.

> **Launch method matters.** A permission grant attaches to the *responsible*
> process. Run the binary from a terminal and the grant lands on Terminal, not
> SpeechLocal — and `AXIsProcessTrusted()` will cheerfully return `true` because it
> inherited the terminal's grant. Always test through the bundle.

Verify:

```bash
make doctor
```

Should print `ALL CHECKS PASS`.

## 5. Run

```bash
open dist/SpeechLocal.app --args --listen
```

A small capsule appears at the bottom of the screen. Hold **Right Option** and
speak.

---

## Make targets

| Target | Does |
|---|---|
| `make test` | Swift Testing suite |
| `make cert` | One-time self-signed identity |
| `make bundle` | Assemble `dist/SpeechLocal.app` |
| `make sign` | Bundle + sign + verify |
| `make doctor` | Run diagnostics inside the signed bundle |
| `make clean` | Remove `.build` and `dist` |

## Notes for contributors

Several things here look wrong and are not. They cost real time to discover:

- **XCTest does not exist in Command Line Tools** — it ships with Xcode. Tests
  use Swift Testing (`import Testing`).
- **Swift Testing needs manual paths under CLT.** `Testing.framework` and
  `lib_TestingInterop.dylib` live in two *different* CLT directories and SwiftPM
  adds neither. The `test` target passes `-F` plus two `-rpath` flags; without
  them the test bundle fails to `dlopen`.
- **The entitlements file must contain no XML comments.** AMFI's parser rejects
  them outright (*"AMFIUnserializeXML: syntax error"*).
- **The hardened runtime denies the microphone silently** without
  `com.apple.security.device.audio-input`. No prompt appears, authorization
  status stays `notDetermined`, and `AVAudioEngine` starts happily and delivers
  silence — it looks exactly like a bug in your own code.
- **A menu-bar app must be a real `.app` bundle.** A bare SwiftPM binary crashes
  on `NSStatusBar` with a `CGSConnectionByID` assertion.
- **Benchmarks must check machine load first.** The same cleanup configuration
  measured 947 ms idle and 7 s under load 52. A benchmark taken during Spotlight
  indexing is fiction.
