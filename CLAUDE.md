# SpeechLocal

A macOS menu-bar app: hold a key and speak to dictate anywhere, or record a
meeting and get a note. Entirely on-device — **no network at runtime** is the
constraint every design decision here bends around.

Swift 6, SwiftPM, no Xcode. Two targets: `SpeechLocalCore` (pure logic, unit
tested) and `SpeechLocal` (AppKit/SwiftUI app).

## Where things are

| You need | Go to |
|---|---|
| How a change gets made and verified here | `docs/CONTEXT.md` |
| Why something is built the way it is | `docs/decisions/` |
| Environment traps that have cost hours | `docs/traps.md` |
| How to prove a subsystem works | `docs/verification.md` |
| What the app does, for a user | `README.md` |
| Build, sign, permissions | `BUILDING.md` |
| Measured spikes from the original build | `clone-run/research.md` |
| The original cloneify run (historical) | `clone-run/` |
| Pure logic, all unit tested | `Sources/SpeechLocalCore/` |
| App, windows, menu bar, wiring | `Sources/SpeechLocal/` |

## Before you change anything

1. **Read `docs/traps.md` first if you are about to build, sign, launch, or
   test the running app.** Every entry in it is something that already went
   wrong and looked like a code bug when it was not.
2. Logic goes in `SpeechLocalCore` with a test. The app target is wiring.
3. `make test` must pass before a commit. `make all` builds and signs.
4. Verify against the real app, not only tests — `docs/verification.md` says
   how. Several bugs here were invisible to a green suite.

## The one rule that keeps being re-learned

**Do not trust a change until it has been run.** The tap that "worked",
the memory that was "flat", the prompt that "would not invent" — each was
believed on inspection and disproved by measurement. Evidence lives in
`docs/decisions/`; opinions do not.
