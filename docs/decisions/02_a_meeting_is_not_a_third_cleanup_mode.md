# A meeting is a separate subsystem, not a third `CleanupMode`

**Decided** 2026-08-22 · **Evidence** the call sites, listed below

Adding `.meeting` to `CleanupMode` looked like the small change. `CleanupMode`
is a dictionary key in `HotkeyManager.bindings` and `.gestures`,
`Listener.sessionSamples`, `Settings.isValid` and `resolvingConflicts`, and it
drives two Settings pickers and three hard-coded menu labels. A third case
ripples through all of them.

For nothing: a meeting starts from a window, not a held key, so it never needs
to be a hotkey mode at all.

`MeetingSession` is its own actor with its own lifecycle. It also let the
5-minute `HotkeyGesture.maxToggleDuration` cap stay where it belongs — on the
gesture, which meetings do not use.
