<p align="center">
  <img src="VoiceJar/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="VoiceBee" width="128" />
</p>

<h1 align="center">VoiceBee</h1>

<p align="center">
  <strong>Hold a key, speak, release — your words appear at the cursor in any app.</strong><br/>
  Native macOS voice input, fully local-first.
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh.md">中文</a>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-1f425f?style=flat-square" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-fa7343?style=flat-square" />
  <img alt="License" src="https://img.shields.io/badge/license-MIT-2f855a?style=flat-square" />
  <img alt="Local-first" src="https://img.shields.io/badge/local--first-✓-805ad5?style=flat-square" />
</p>

---

## Demo

<p align="center">
  <img src="docs/demo.gif" alt="VoiceBee demo — hold key, speak, release" width="640" />
</p>

> 📹 To regenerate: `Cmd+Shift+5` → "Record Selected Portion" → record 20–30s of "hold key → speak Chinese with ChatGPT-style prompt → release → text appears in the editor". Save as `docs/demo.gif` (use [Gifski](https://gif.ski/) or `ffmpeg -i input.mov -vf "fps=15,scale=640:-1" -c:v gif docs/demo.gif`).

## Why VoiceBee

VoiceBee is a native macOS voice input app for any text field — ChatGPT, Claude, Cursor, Notion, your editor, your terminal. Hold a key, speak, release. The transcript appears at the cursor.

**The differentiator: it can run with zero network.** VoiceBee uses Apple's built-in speech recognizer for transcription (default) or a fully local WhisperKit Whisper model (opt-in via settings), and supports Ollama for local LLM polishing — meaning the entire pipeline can stay on your machine. No API keys, no audio uploads, no vendor account.

You can also point it at Claude / DeepSeek / Gemini / OpenAI-compatible endpoints if you want a stronger polish model — but you don't have to.

## Comparison

| Tool | Voice → Text | LLM Polish | Setup | Local-only mode |
|---|---|---|---|---|
| **VoiceBee** | Apple SFSpeech (built-in, free) or WhisperKit (local Whisper, opt-in) | Ollama / Claude / DeepSeek / Gemini / OpenAI | Zero config | ✅ Apple ASR or WhisperKit + Ollama |
| OpenLess | Volcengine cloud ASR | Ark / DeepSeek / OpenAI | Requires cloud API keys | ❌ |
| Wispr Flow | Cloud (proprietary) | Cloud (proprietary) | Subscription account | ❌ |
| Typeless | Cloud (proprietary) | Cloud (proprietary) | Subscription account | ❌ |
| Superwhisper | Whisper (local) | Cloud or local | Manual model download | ✅ Whisper local |

## Features

- **Two ASR engines**: Apple SFSpeech (default, zero setup) or WhisperKit large-v3 (fully local Whisper model, downloaded and managed in-app) — switchable in settings.
- **Customizable recording hotkey**: any single modifier (Fn, left/right ⌘ ⌥ ⇧ ⌃) or key combo, in hold (push-to-talk) or toggle (click to start/stop, 30-min safety timeout) mode, with system-shortcut conflict warnings. Double-tap the modifier switches output style on the fly.
- **Four output styles**: raw (punctuation only) → light (filler removal) → structured (bullet reorganization) → formal (professional wording).
- **Streaming**: text shows up as it's being polished — no waiting for the whole response.
- **Translate hotkey** (⌥T default, customizable): select text in any app, hit the hotkey, get a translation in your clipboard.
- **Dictation translation**: tap a marker key (Shift / Ctrl / Option / Fn) while recording to route that dictation through translation into your target language.
- **Vocab dictionary**: add proper nouns (Claude, ChatGPT, your team's names) — they're injected as ASR contextual hints, polish-time semantic prompts, AND a post-ASR spelling corrector (exact alias match + Levenshtein fuzzy) that fixes misheard proper nouns before polish.
- **Repeat last injection** (⌥⇧V default): re-paste the last dictation result.
- **Auto-learn vocab**: VoiceBee mines candidate proper nouns from your history, you add them with one click.
- **Usage stats**: total chars, time saved (vs 60-cpm typing baseline), top hit terms.
- **Sparkle auto-update**: in-app "Check for Updates" button + scheduled background checks.
- **Single-instance lock**: prevents two VoiceBee processes from racing the same hotkey edge.
- **Robust event tap**: self-healing CGEventTap (macOS occasionally disables event taps) + accessibility permission auto-polling.
- **Clipboard restore**: after pasting, the previous clipboard content is restored automatically.

## Quick start

### Install

Download the latest `.dmg` from [VoiceBee-Releases](https://github.com/answer2023/VoiceBee-Releases/releases) and drag to `/Applications`.

**Apple Silicon required** (the build is arm64-only). The DMG is not notarized yet, so on first open Gatekeeper may block it — right-click the app → Open once to bypass.

On first launch, grant the permissions VoiceBee asks for:
1. **Microphone** — for recording.
2. **Speech recognition** — for transcription (Apple's built-in service).
3. **Accessibility** — for the global hotkey listener and pasting at the cursor.

Open Settings (click the menu bar mic icon) → fill in the AI engine you want for polish (or pick "Ollama" if you have it running locally for full offline mode).

### Build from source

Requires macOS 14+, Xcode 16.3+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/answer2023/VoiceBee.git
cd VoiceBee
xcodegen
xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar -configuration Release build
```

The built `.app` is signed with an ad-hoc signature suitable for local use.

## Architecture

```
VoiceJarMain           Single-instance lock + NSApplication lifecycle
VoiceJarDelegate       Menu bar, settings windows, permission requests
VoiceEngine            Coordinator: hotkey → ASR stream → vocab-correct → polish → inject
HotkeyManager          CGEventTap (self-healing); modifier-only & combo hotkeys, hold/toggle, double-tap
HotkeyConflictChecker  System-shortcut blacklist + internal hotkey conflict warnings
ASRProvider            Protocol abstracting ASR engines — each provider owns its mic/audio pipeline
SFSpeechProvider       SFSpeechRecognizer streaming + contextualStrings injection (default engine)
WhisperKitProvider     WhisperKit large-v3 local model; download/status managed in Application Support
VocabPostprocessor     Post-ASR proper-noun correction: alias exact match + Levenshtein fuzzy
PolishService          Ollama (local/cloud) / Claude / DeepSeek / Gemini / OpenAI-compatible (SSE streaming)
TextInjector           Clipboard + ⌘V with changeCount-aware restore
VocabStore             ~/Library/Application Support/VoiceBee/vocab.json
StatsStore             UserDefaults cumulative counters
UpdaterManager         Sparkle 2 wrapper
```

The dictation pipeline:
```
hotkey down → ASRProvider.startStreaming(language, vocabHint) — provider runs its own mic capture
[partial transcripts stream to the overlay]
hotkey up → provider finalizes → VocabPostprocessor.apply(finalText, vocab)
→ PolishService.polishStream(outputStyle, vocabTerms)   (or translate(targetLang) if marked mid-recording)
→ TextInjector.inject
→ StatsStore.record + VocabStore.recordHits + history
```

## Privacy

- All credentials are stored in the macOS Keychain (`com.clearsky.VoiceJar`).
- Audio never leaves your machine when you use Apple ASR + Ollama; with WhisperKit the ASR model itself also runs entirely on-device.
- When you choose a cloud LLM (Claude / DeepSeek / Gemini / OpenAI), only the **transcript** is sent — never raw audio.
- The polish model is prompted to clean up the text only; it is told **not** to answer questions or execute instructions inside the transcript.

## Maintainer release checklist

Releases are a **local manual flow** — there is no CI release pipeline (the old `release.yml` was removed 2026-07; it targeted the private repo and would have required exporting the Sparkle private key into GitHub Secrets). CI (`ci.yml`) only runs build + test + SwiftLint as a quality gate.

To cut a new release:

```bash
# 1. Bump Info.plist (CFBundleShortVersionString + CFBundleVersion)
# 2. Run the release script (build → version check → DMG → Sparkle-sign)
./scripts/release.sh 1.x.x
# 3. Follow the script's printed steps: prepend the new <item> to appcast.xml
#    in VoiceBee-Releases, publish the GitHub Release there (two DMG assets),
#    then commit the version bump + tag in this repo.
```

Full details (dual-repo model, appcast, notarization status): see [docs/RELEASE.md](docs/RELEASE.md).

## License

MIT
