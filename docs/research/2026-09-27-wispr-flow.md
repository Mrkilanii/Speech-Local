# How Wispr Flow works (as of 27 Sep 2026), for SpeechLocal

Tags: **[S#]** = SOURCE-STATED (numbered source list at end). **[INF]** = INFERRED by me. **[3P]** = third-party claim (reviews, competitor blogs); not verified.

## 1. Pipeline

- **Cloud only.** "Transcription always occurs on the cloud." [S1] With no internet the app shows "No internet. Try again later."; failed audio is kept for retry for 14 days [S2][S3]. There is no offline mode.
- **Two stages: ASR, then an LLM.** A fine-tuned **Llama** does the "real-time transcript cleanup step", served by Baseten on AWS using TensorRT-LLM [S4]. The model size is not published. Third-party LLMs are also used for "certain features" under zero-data-retention agreements, and no vendor is named [S1][S5].
- **ASR models.** For a long time Flow used third-party engines: Flow "dynamically selects the most accurate ASR engine for each language" out of "an ensemble of speech recognition models". The same page compares ElevenLabs Scribe, Gemini and Whisper, and describes "accent confidence scoring" that picks among several transcriptions [S6]. On 17 Sep 2026 Wispr shipped **Canto**, "the first speech model we've built ourselves". It is English only, post-trained with SFT and then GRPO, and it takes the user's dictionary as context at runtime. It was trained with phonetically similar distractors so it learns when to ignore context. Wispr reports the lowest WER on its own dictation set against Google, OpenAI, AssemblyAI and Deepgram [S7][S8]. [INF] Non-English audio probably still goes through the third-party ensemble.
- **Latency targets.** The whole run must finish **within 700 ms of when the user stops speaking**: ASR under 200 ms, LLM under 200 ms, network under 200 ms [S9]. The 700 ms is measured at **p99**, and the LLM must produce "100+ tokens in <250 ms" [S4]. In June 2026 they reported latency "down 30% since the start of the year" [S8]. After about 4 s the app shows "Taking longer than usual" [S2].
- **Streaming or send on release.** Their public WebSocket API streams 16 kHz int16 PCM in chunks of about 1 s ("append" messages, then a "commit"), and returns partial and final results [S10]. [INF] The desktop app most likely streams audio while you hold the key and runs the LLM only after release. The 700 ms "after stop speaking" budget only works if ASR is mostly done before release. No primary source states this for the app.

## 2. Text insertion on macOS

- **Clipboard paste.** Flow "briefly uses the clipboard to insert text, then restores its previous contents" [S11]. On Mac it needs Accessibility access to insert text [S12]. [INF] It synthesises ⌘V, which Accessibility permission allows. The docs say only "clipboard and keyboard shortcuts".
- **Restore rules.** The previous clipboard comes back **after about 0.5 s**. **If you copy something new during that wait, your new copy is kept.** Items that a password manager marked as sensitive keep that marking when restored [S11][S13]. On Mac, files and PDFs are not restored. **If the insert fails, the transcript stays on the clipboard and the old contents are not restored** [S12].
- **Recovery.** The tray menu has "Paste last transcript" and the Mac app menu has Dictation → "Copy last transcript" [S13]. History keeps every transcript on the device and lets you retry [S3].
- **Terminals and AI CLIs.** In May 2026 they changed how text goes into AI coding terminals so it stays visible instead of being collapsed into a paste block [S8].

## 3. Context awareness

- **Fields sent with each request** (API schema [S10]): app `name` and `type` (email/ai/other); `dictionary_context`; `user_identifier` and first/last name; textbox `before_text`, `selected_text`, `after_text`; `screenshot`, `content_text`, `content_html`; and a conversation (participants plus role/content messages).
- **The help-centre list matches:** app info, textbox contents, on-screen text, variable and file names in coding apps, the apps in the current session, **a screenshot**, and conversation history [S14].
- **What the context is used for:** getting proper nouns and capitalisation right (for example, the names of email recipients); matching the casing, spacing and punctuation of the surrounding text; and setting tone. Text near the cursor also decides which of four categories the app falls into: Email, Work messaging, Personal messaging or Other [S14].
- **Exclusions:** passwords and other sensitive or numbers-only fields, URL bars, placeholder text, and banking apps. The feature is **on by default** [S14].
- **In IDEs:** "user ID" can come out as `userId`, which needs VS Code's screen-reader mode. `@file` tagging works by voice ("tag my python script" → `my_python_script.py`) [S15].
- **Privacy history [3P]:** in 2025 a user on Reddit found periodic screenshots going to cloud and third-party AI servers. Wispr banned that user, and the CTO later apologised. Opt-in controls followed [S16]. Only the existence of the screenshot field is confirmed by a primary source [S10][S14].

## 4. Cleanup

- **Backtrack** removes fillers, false starts and self-corrections. Triggers include "actually", "scratch that", "never mind", or simply restating. "Let's do coffee at 2 actually 3" → "Let's do coffee at 3." "I actually enjoyed the movie" is left alone. It "uses your full dictation as context" [S17]. [INF] This is done by the LLM, not by rules.
- **Smart Formatting:** spoken lists ("one… two…", "first… second…") become numbered lists. Spoken punctuation is supported ("period", "comma", "em dash", "new line", "new paragraph" and others). Casing follows the surrounding text. **In messaging apps a trailing period is dropped for dictations of up to two sentences**; ? and ! are kept [S17].
- **Styles:** each app category gets Formal, Casual, "very casual" (Personal only) or "Excited!" (not Personal). Styles change **only capitalisation, punctuation and spacing, never wording**. They work in English only. The desktop default is Formal everywhere [S18][S19].
- **Command Mode** (paid; Fn+Ctrl on Mac): select text and say "make this more formal" or "turn this into a bullet list", and the selection is replaced. It does nothing if there is no text. Without a selection you can say "ask/search/hey + Google/Perplexity/ChatGPT/Claude" to open a web search [S20].
- **Snippets:** triggers up to 60 characters and expansions up to 4,000 characters. Text is static (no date variables). A trigger spoken alone ignores case and punctuation. Inside a sentence the trigger must stand as its own word. The longest matching trigger wins [S21].
- **Dictionary:** you can add entries by hand, with an optional "correct a misspelling" mapping. Matching is on whole words and ignores case, and the longer phrase wins. Words are also learned automatically from your edits and from app context (shown with a ✨ badge), and a deleted word is never re-added [S22][S23]. Custom-prompt requests run without the dictionary [S22].
- **Whispering:** marketing says quiet speech works without a toggle [S24]. The quoted accuracy numbers are [3P].
- **Languages:** 100+ are supported, with auto-detect giving **one language per dictation, not per word**. Hinglish must be selected explicitly. Urdu, Hebrew and Ukrainian cannot be auto-detected [S25].
- **Learning style from edits:** Wispr says this is the goal ("local RL policy", "personalization data must live on a user's device") [S9]. How it is actually implemented is not public.

## 5. Hotkeys and UI

- **Hold to talk:** hold Fn. Macs without an Fn key use Ctrl+Opt [S11].
- **Hands-free:** Fn+Space, or double-tap Fn within 0.5 s of starting. A third quick tap cancels. Bare Caps Lock can also be bound [S26].
- **Stop and cancel:** press the shortcut again or click the stop icon in the Flow Bar to stop. **Esc** or X cancels, and a cancel offers Undo and "Open History". A tap too short to record anything is cancelled [S11][S26].
- **Feedback:** a "ping" plays before you speak [S26], and moving white bars show that recording is active [S11]. The Flow Bar is on by default and can be moved to the left or right edge (June 2026) [S8].
- **Limits:** a warning at 19 min and a stop at 20 min; that audio is still transcribed [S26].

## 6. Names and jargon

Four sources feed this: the dictionary (now passed to Canto as context), screen and textbox context, auto-learning from corrections, and IDE symbol names [S7][S14][S15][S22]. Wispr says "LLMs are phenomenal at recall, but very low precision" when applying preferences [S9].

## 7. Known weaknesses

- **Network dependence:** delays on poor networks and incident-level latency spikes (their status page lists a "Slow Performance / Latency" incident) [S27]. There is no offline mode [S1].
- **Privacy:** screenshots and on-screen text go to the cloud by default. Third-party LLMs are unnamed. The 2025 ban incident is [3P] [S16].
- **Resources [3P]:** the Electron app reportedly uses about 800 MB RAM and several % CPU when idle [S28].
- **Formatting limits:** Styles are English only. Code-switching is weak (Chinese/English script mixing) [S25]. Failed Command Mode edits fail silently [S20].
- **Cost [3P]:** about $15/month for Pro [S29].

## Gap vs a local clone (M1, SpeechAnalyzer + rules + FoundationModels ~3B)

| Wispr feature | Reproducible on-device? | Main obstacle |
|---|---|---|
| Latency (≤700 ms p99 after release) | **Yes, can beat it.** There is no network leg, and SpeechAnalyzer streams, so ASR is finished at release. | The FM 3B generating 100+ tokens is roughly seconds, not 250 ms [INF]. Keep the LLM off the hot path or limit it to short rewrites. |
| ASR accuracy | **Partly.** | SpeechAnalyzer is not Canto. The custom vocabulary hints are weaker than context-trained biasing, and on-device models have no speaker adaptation. |
| Clipboard paste with 0.5 s restore, new-copy wins, sensitive marker kept, "paste last" | **Fully.** | None. It is NSPasteboard changeCount plus a CGEvent ⌘V, and org.nspasteboard.ConcealedType for the sensitive marker. |
| Textbox context (before/selected/after) | **Fully**, through the AX API (kAXValue, kAXSelectedTextRange). | Electron and web apps expose AX unevenly. |
| Screenshot OCR for names | **Technically yes** (ScreenCaptureKit + Vision). | Needs Screen Recording permission. Cost, and the privacy optics. |
| Backtrack / self-correction | **Rules handle explicit triggers only.** | Implicit restatement ("gift… as a present") needs semantic judgement. The 3B model is unreliable here and may drop real content. Wispr's own note on low LLM precision applies even more to a smaller model. |
| Fillers, spoken punctuation, numbered lists, dropping trailing periods in chat | **Fully, with rules.** | None. These are deterministic. |
| Styles (case/punctuation/spacing only) | **Fully, with rules.** | None. By Wispr's own definition this is a formatting transform, not an LLM rewrite. |
| Command Mode (rewrite selection) | **Partly.** | 3B quality on "make formal" or "translate" is clearly below a cloud LLM. Web-search commands cannot work offline. |
| Snippets | **Fully.** | None. |
| Dictionary, manual + "correct misspelling" | **Fully.** | None. |
| Auto-learning from edits | **Mostly.** Re-read the field via AX after the insert and diff it. | Telling a real correction apart from a later rewrite. |
| Multilingual auto-detect | **Partly.** | SpeechAnalyzer needs the locale chosen up front and has no auto language detection [INF]. |
| Whispering | **Unknown.** | Needs measurement with Apple's on-device model. |
| Large-LLM rewrite quality overall | **No.** | A fine-tuned Llama in the cloud, trained on millions of real user edits, cannot be matched by a general 3B model. Aim for deterministic correctness, and use the LLM only where the rules abstain. |

## Sources

- S1 https://wisprflow.ai/data-controls
- S2 https://docs.wisprflow.ai/articles/4984532368-fix-taking-longer-than-usual-and-transcription-errors
- S3 https://docs.wisprflow.ai/articles/2503460374-retry-failed-transcriptions
- S4 https://www.baseten.co/resources/customers/wispr-flow/
- S5 https://wisprflow.ai/privacy-policy
- S6 https://wisprflow.ai/research/supporting-languages
- S7 https://wisprflow.ai/canto
- S8 https://wisprflow.ai/whats-new
- S9 https://wisprflow.ai/post/technical-challenges (also /research/technical-challenges)
- S10 https://api-docs.wisprflow.ai/websocket_api
- S11 https://docs.wisprflow.ai/articles/6409258247-starting-your-first-dictation
- S12 https://docs.wisprflow.ai/articles/7971211038-fix-text-not-pasting-after-dictation
- S13 https://docs.wisprflow.ai/articles/6478598909-using-flow-with-linux-wsl-and-terminal-applications (search-snippet text; the page itself was not opened)
- S14 https://docs.wisprflow.ai/articles/4678293671-feature-context-awareness
- S15 https://docs.wisprflow.ai/articles/6434410694-use-flow-with-cursor-vs-code-and-other-ides
- S16 [3P] https://modelpiper.com/blog/wispr-flow-privacy-incident , https://www.getvoibe.com/resources/is-wispr-flow-safe/
- S17 https://docs.wisprflow.ai/articles/5373093536-how-do-i-use-smart-formatting-and-backtrack
- S18 https://docs.wisprflow.ai/articles/2368263928-how-to-setup-flow-styles
- S19 https://wisprflow.ai/post/personalized-style
- S20 https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
- S21 https://docs.wisprflow.ai/articles/5784437944-create-and-use-snippets
- S22 https://docs.wisprflow.ai/articles/4052411709-teach-flow-your-words-with-the-dictionary
- S23 https://wisprflow.ai/features (auto-add and ✨ badge, from search snippets)
- S24 https://wisprflow.ai/microphones
- S25 https://docs.wisprflow.ai/articles/3191899797-use-flow-with-multiple-languages
- S26 https://docs.wisprflow.ai/articles/6391241694-use-flow-hands-free
- S27 https://statuspage.incident.io/wispr-flow/incidents/01KFH1SEDXQSREP1CHMPXVHR47
- S28 [3P] https://www.getvoibe.com/resources/wispr-flow-review/ , https://spokenly.app/blog/wispr-flow-review
- S29 [3P] https://dev.to/omachala/i-stopped-paying-15month-for-wispr-flow-heres-the-open-source-replacement-313i

Caveat: the pages were read through a summarising fetcher, so the quoted phrases are close to the source but should be spot-checked before they are cited as exact wording.
