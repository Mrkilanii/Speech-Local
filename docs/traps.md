# Traps

Environment behaviours that look like code bugs. Every one of these has already
cost hours here. Read before building, signing, launching, or testing the
running app.

## Launching

**`open --args` does nothing to an app that is already running.** It activates
the existing instance and drops the arguments silently — so a probe appears not
to run, and the log you are reading is the previous run's. Kill first, or force
a new instance:

```bash
killall SpeechLocal; open -n dist/SpeechLocal.app --args --probe-meeting 300
```

**A rebuild does not reach the running app.** `make all` writes a new bundle;
the process keeps the old binary until relaunched. A fix that "did not work" is
usually a stale process — check the app's start time against the binary's.

**Launch the bundle, never the binary.** macOS attaches permission grants to
the *responsible* process, so running from a terminal grants them to Terminal.
`AXIsProcessTrusted()` then returns true for the wrong reason.

## Signing

**`codesign` blocks on a keychain dialog that cannot always be shown.** With
the screen locked or the user away, it hangs indefinitely with no output. First
signing after a change needs somebody at the keyboard.

**Do not kill `codesign` mid-run.** It leaves a bundle that fails
`--verify --strict` with "code has no resources but signature indicates they
must be present". `rm -rf dist/SpeechLocal.app && make all` to recover.

## Audio

**A process tap delivers nothing until `NSApplication` exists.** TCC needs a
WindowServer connection to attribute the tap to this bundle. Started from
top-level code before the app is up, `AudioHardwareCreateProcessTap` succeeds,
`AudioDeviceStart` returns `noErr`, and the IOProc never fires — no error
anywhere. `AudioSourceProbe` initializes `NSApplication` first for this reason.

**Zero buffers with nothing playing is correct.** An idle output device has no
IO cycle, so a tap has nothing to deliver. Silence and "not running" look
identical from the ring buffer; the buffer counter in `SystemAudioTap` exists
to tell them apart.

**Protected audio is silent by design.** DRM sources (Apple Music, Netflix,
protected browser streams) cannot be captured by any path. Two independent APIs
reporting silence means the source, not the code.

## Shell

**`pkill -f <pattern>` matches its own shell.** The pattern appears in the
command line of the shell running it, so it kills itself mid-script. Use
`killall SpeechLocal`.

**`cd` persists between tool calls.** A `cd` into another directory leaves
later commands there — including `git status`, which will then report on the
wrong repository.

## Tests

**Fixed sleeps race the drain.** `MeetingSession` pumps once a second; a test
that sleeps 1.1 s and asserts fails about one run in three on a loaded machine.
Wait on the condition — see `until` in `MeetingSessionTests`.

**The suite crashes intermittently in teardown.** An objc "Hash table
corrupted" abort after every test has already reported passing. Pre-existing,
unrelated to any change; re-run before investigating.
