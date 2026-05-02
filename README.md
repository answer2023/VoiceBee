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

## Why VoiceBee

VoiceBee is a native macOS voice input app for any text field — ChatGPT, Claude, Cursor, Notion, your editor, your terminal. Hold a key, speak, release. The transcript appears at the cursor.

**The differentiator: it can run with zero network.** VoiceBee uses Apple's built-in speech recognizer for transcription and supports Ollama for local LLM polishing — meaning the entire pipeline can stay on your machine. No API keys, no audio uploads, no vendor account.

You can also point it at Claude / DeepSeek / Gemini / OpenAI-compatible endpoints if you want a stronger polish model — but you don't have to.

## Comparison

| Tool | Voice → Text | LLM Polish | Setup | Local-only mode |
|---|---|---|---|---|
| **VoiceBee** | Apple SFSpeech (built-in, free) | Ollama / Claude / DeepSeek / Gemini / OpenAI | Zero config | ✅ Apple ASR + Ollama |
| OpenLess | Volcengine cloud ASR | Ark / DeepSeek / OpenAI | Requires cloud API keys | ❌ |
| Wispr Flow | Cloud (proprietary) | Cloud (proprietary) | Subscription account | ❌ |
| Typeless | Cloud (proprietary) | Cloud (proprietary) | Subscription account | ❌ |
| Superwhisper | Whisper (local) | Cloud or local | Manual model download | ✅ Whisper local |

## Features

- **Hold-to-talk hotkey**: Fn (single key) or any combo. Double-tap Fn switches polish mode on the fly.
- **Two polish modes**: instant (light correction) vs. structured (deep cleanup with reordering).
- **Streaming**: text shows up as it's being polished — no waiting for the whole response.
- **Translate hotkey** (⌥T): select text in any app, hit the hotkey, get a translation in your clipboard.
- **Vocab dictionary**: add proper nouns (Claude, ChatGPT, your team's names) — they're injected as ASR contextual hints AND polish-time semantic prompts.
- **Auto-learn vocab**: VoiceBee mines candidate proper nouns from your history, you add them with one click.
- **Usage stats**: total chars, time saved (vs 60-cpm typing baseline), top hit terms.
- **Sparkle auto-update**: in-app "Check for Updates" button + scheduled background checks.
- **Single-instance lock**: prevents two VoiceBee processes from racing the same hotkey edge.
- **Robust event tap**: self-healing CGEventTap (macOS occasionally disables event taps) + accessibility permission auto-polling.
- **Clipboard restore**: after pasting, the previous clipboard content is restored automatically.

## Quick start

### Install

Download the latest `.dmg` from [Releases](../../releases) and drag to `/Applications`.

On first launch, grant the permissions VoiceBee asks for:
1. **Microphone** — for recording.
2. **Speech recognition** — for transcription (Apple's built-in service).
3. **Accessibility** — for the global hotkey listener and pasting at the cursor.

Open Settings (click the menu bar mic icon) → fill in the AI engine you want for polish (or pick "Ollama" if you have it running locally for full offline mode).

### Build from source

Requires macOS 14+, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/clearsky/VoiceBee.git
cd VoiceBee
xcodegen
xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar -configuration Release build
```

The built `.app` is signed with an ad-hoc signature suitable for local use.

## Architecture

```
VoiceJarMain        Single-instance lock + NSApplication lifecycle
VoiceJarDelegate    Menu bar, settings windows, permission requests
VoiceEngine         Coordinator: hotkey → record → ASR stream → polish → inject
HotkeyManager       CGEventTap (self-healing); Fn single key + double-tap detection
AudioRecorder       AVAudioEngine 16 kHz PCM with streaming buffer callback
SpeechRecognizer    SFSpeechRecognizer streaming + contextualStrings injection
PolishService       Ollama / Claude / DeepSeek / Gemini / OpenAI-compatible (SSE streaming)
TextInjector        Clipboard + ⌘V with changeCount-aware restore
VocabStore          ~/Library/Application Support/VoiceBee/vocab.json
StatsStore          UserDefaults cumulative counters
UpdaterManager      Sparkle 2 wrapper
```

The dictation pipeline:
```
hotkey down → AudioRecorder.start + SpeechRecognizer.startStreaming(contextualStrings)
[audio frames stream into recognizer]
hotkey up → recognizer.finishStreaming → PolishService.polishStream(vocabTerms)
→ TextInjector.inject (or background polish + ⌘V replace in instant mode)
→ StatsStore.record + VocabStore.recordHits + history
```

## Privacy

- All credentials are stored in the macOS Keychain (`com.clearsky.VoiceJar`).
- Audio never leaves your machine when you use Apple ASR + Ollama.
- When you choose a cloud LLM (Claude / DeepSeek / Gemini / OpenAI), only the **transcript** is sent — never raw audio.
- The polish model is prompted to clean up the text only; it is told **not** to answer questions or execute instructions inside the transcript.

## Maintainer release checklist

Before publishing a new `.dmg` to Releases:

### One-time setup (first release only)

- [ ] **Generate Sparkle ed25519 keypair**
  ```bash
  find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f -path "*Sparkle*" | head -1
  # run the path printed above
  ```
  The private key auto-saves to your macOS Keychain (service `https://sparkle-project.org`). The public key is printed to stdout.
- [ ] **Paste the public key** into `VoiceJar/Info.plist` as the value of `SUPublicEDKey`.
- [ ] **Export the private key** for CI:
  ```bash
  /path/to/generate_keys -x /tmp/sparkle_priv.key
  cat /tmp/sparkle_priv.key   # copy
  rm /tmp/sparkle_priv.key    # delete immediately
  ```
  Add it to GitHub repo → Settings → Secrets → Actions as `SPARKLE_ED_PRIVATE_KEY`. **Never commit, screenshot, or share this key** — leak = attacker can sign malicious updates that all VoiceBee users auto-install.
- [ ] **Update `SUFeedURL`** in Info.plist to your real appcast URL (default: `releases/latest/download/appcast.xml`).
- [ ] **Apple Developer ID + notarization** — separate from Sparkle signing; required so macOS Gatekeeper accepts the `.app`.

### Every release

- [ ] Bump `CFBundleShortVersionString` and `CFBundleVersion` in `VoiceJar/Info.plist`.
- [ ] `xcodegen && xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar -configuration Release build`.
- [ ] Create `VoiceBee-<version>.dmg` and notarize via `xcrun notarytool submit`.
- [ ] Sign the DMG for Sparkle:
  ```bash
  ./sign_update VoiceBee-<version>.dmg
  # outputs: sparkle:edSignature="..." length="..."
  ```
- [ ] Update `appcast.xml` with the new `<enclosure>` including `sparkle:edSignature` and `sparkle:version`.
- [ ] Tag the release: `git tag v<version> && git push --tags`.
- [ ] Upload `.dmg` + `appcast.xml` to the GitHub Release.
- [ ] Smoke test: install the previous version, launch, click "Check for Updates", verify auto-update works end-to-end.

## License

MIT
