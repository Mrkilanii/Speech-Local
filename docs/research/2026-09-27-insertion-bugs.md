# SpeechLocal insertion bugs — evidence, 2026-09-27

Read from `Sources/SpeechLocalCore/TextInserter.swift` (HEAD 9c9d894) and
`~/Library/Logs/SpeechLocal/doctor.log` (22,251 lines, 16 Aug – 27 Sep).

## 1. The paste restores the user's clipboard 120 ms after ⌘V

`insertViaPaste` writes the transcript to the general pasteboard, posts ⌘V,
sleeps 0.12 s, and a `defer` then restores whatever was on the clipboard
before. The target app reads the pasteboard when it handles ⌘V. If that takes
more than 120 ms, it reads the restored contents and pastes the user's old
clipboard instead of the dictation. That is Omar's report word for word:
"it'll paste whatever I have copied to clipboard instead of what I spoke."

- 2,805 of 2,826 logged insertions went through paste; 21 through Accessibility.
  Paste is the path, not the fallback.
- Top paste targets: Claude desktop 2,018, ChatGPT/Codex 213, Arc 121,
  Chrome 107. All Electron or Chromium, where ⌘V is handled asynchronously in
  a renderer process — the case most likely to exceed 120 ms under load.
- Not measured: the actual read delay in any app. Nothing in the log records
  when the target read the pasteboard, so the frequency of the failure is
  unknown. The mechanism is certain from the code; the rate is not.

A lazy pasteboard item (`NSPasteboardItem` + `NSPasteboardItemDataProvider`)
calls back when data is requested, which gives the read time directly — both a
way to measure and a way to restore only after the read. Caveat: a clipboard
manager (Raycast is installed) may request the data first. The
`org.nspasteboard.TransientType` / `ConcealedType` markers are the convention
clipboard managers honour to skip an item.

## 2. Dictation was pasted blind into the macOS password prompt

`FOCUS none app=SecurityAgent bundle=com.apple.SecurityAgent` followed by
`INSERT via paste`, three times (log lines 535, 660, 852 — August). With no
focused accessibility element, `insert` pastes blind to the frontmost app, and
the secure-field check (`rejectSecureField`) only runs when an element exists.
SecurityAgent is the system authentication dialog. Whatever was dictated went
into (or at) a password field.

Checkable guards: refuse when the frontmost bundle is `com.apple.SecurityAgent`
or `com.apple.loginwindow`, and when `IsSecureEventInputEnabled()` is true.
