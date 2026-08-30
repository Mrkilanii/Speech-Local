# System audio uses a CoreAudio process tap, not ScreenCaptureKit

**Decided** 2026-08-22 · **Evidence** `clone-run/research.md` §9, both measured

Both capture identically: tap **rms 0.1320 / 299,520 frames**, ScreenCaptureKit
**rms 0.1348 / 306,240 frames**, six seconds each.

Chosen on cost, not quality. The tap is audio asking for audio permission.
ScreenCaptureKit means opening a screen-capture session, discarding its video,
requesting Screen Recording, and lighting the purple capture indicator on a
note-taking app.

**Held to:** `muteBehavior = .unmuted`. Tapping the output must never silence
the speakers the user is listening through.

**Kept but not required:** the aggregate device is anchored to the default
output as its clock. That was added chasing a tap delivering zero buffers, on a
theory the evidence later disproved — the real cause was that nothing
capturable was playing. The spike captures fine without it. It stays because it
is what was measured working end to end.
