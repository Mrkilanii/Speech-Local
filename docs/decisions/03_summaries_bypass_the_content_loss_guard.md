# Summaries do not go through `RoutingCleanupEngine`

**Decided** 2026-08-22 · **Evidence** `contentLoss` rejects at 25%; a test pins it

`RoutingCleanupEngine.contentLoss` rejects any output under **25%** of its
input's word count and falls back to the raw transcript. It exists because the
model once returned truncated and empty text with no error raised, and it is
right for what it guards.

A 9,000-word meeting summarised to 900 words is a tenth of the input. Routed
through that guard, every summary would be silently replaced by the raw
transcript — indistinguishable, by word count alone, from the failure the guard
was built to catch.

So `MeetingSummarizer` talks to `FoundationModels` directly.
`aSummaryWouldBeRejectedByTheCleanupGuard` in `MeetingSummarizerTests` asserts
the guard would indeed reject one, so the reason cannot be lost.
