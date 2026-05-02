<p align="center">
  <img src="VoiceJar/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" alt="VoiceBee" width="128" />
</p>

<h1 align="center">VoiceBee</h1>

<p align="center">
  <strong>按住快捷键说话，松开即在光标处出现文字。</strong><br/>
  原生 macOS 语音输入，全本地优先。
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh.md">中文</a>
</p>

<p align="center">
  <img alt="macOS" src="https://img.shields.io/badge/macOS-14%2B-1f425f?style=flat-square" />
  <img alt="Swift" src="https://img.shields.io/badge/Swift-6.0-fa7343?style=flat-square" />
  <img alt="License" src="https://img.shields.io/badge/license-MIT-2f855a?style=flat-square" />
  <img alt="本地优先" src="https://img.shields.io/badge/本地优先-✓-805ad5?style=flat-square" />
</p>

---

## 演示

<p align="center">
  <img src="docs/demo.gif" alt="VoiceBee 演示 — 按住、说话、松开" width="640" />
</p>

> 📹 录制方法：`Cmd+Shift+5` → "录制选定区域" → 录 20–30 秒"按住键→说一段中文 prompt→松开→文字出现在编辑器"。存为 `docs/demo.gif`（用 [Gifski](https://gif.ski/) 或 `ffmpeg -i input.mov -vf "fps=15,scale=640:-1" -c:v gif docs/demo.gif`）。

## 为什么选 VoiceBee

VoiceBee 是原生 macOS 语音输入工具：在任意输入框（ChatGPT、Claude、Cursor、Notion、编辑器、终端...）按住快捷键说话，松开即上屏。

**最大差异化：可以零网络运行。** 识别用 Apple 自带的 SFSpeechRecognizer，润色支持 Ollama 本地模型 —— 全链路不出本机。无需 API Key，无需上传音频，无需注册账号。

如果你想要更强的润色效果，也可以接 Claude / DeepSeek / Gemini / OpenAI 兼容端点 —— 但这是可选项。

## 对比

| 工具 | 语音识别 | LLM 润色 | 配置门槛 | 全本地模式 |
|---|---|---|---|---|
| **VoiceBee** | Apple SFSpeech（系统内置，免费） | Ollama / Claude / DeepSeek / Gemini / OpenAI | 零配置 | ✅ Apple ASR + Ollama |
| OpenLess | 火山引擎云 ASR | Ark / DeepSeek / OpenAI | 需要云端 API Key | ❌ |
| Wispr Flow | 云端（闭源） | 云端（闭源） | 订阅账号 | ❌ |
| Typeless | 云端（闭源） | 云端（闭源） | 订阅账号 | ❌ |
| Superwhisper | Whisper（本地） | 云端或本地 | 手动下载模型 | ✅ Whisper 本地 |

## 功能

- **按住说话**：Fn 单键 或 任意组合键。双击 Fn 即时切换润色模式。
- **两档润色**：即时（轻度纠错） / 润色（深度整理 + 重组）。
- **流式输出**：润色文字逐字出现，无需等待完整响应。
- **翻译快捷键**（⌥T）：选中任意文字，按下即得翻译并复制到剪贴板。
- **词典**：添加专名（Claude、ChatGPT、人名）—— 同时作为 ASR 热词 + 润色语义提示双通道注入。
- **词典自学习**：从历史中挖掘候选专名，一键加入。
- **使用统计**：累计字数、节省时间（基于 60 字/分钟手打基准）、词典命中排行。
- **Sparkle 自动更新**：内置"检查更新"按钮 + 后台周期检查。
- **单实例锁**：防止两个 VoiceBee 进程抢同一个 Fn 边沿。
- **健壮事件 Tap**：CGEventTap 自愈（macOS 偶尔会自动关闭 event tap） + 辅助功能权限自动轮询。
- **剪贴板自动恢复**：粘贴后自动还原原剪贴板内容。

## 快速开始

### 安装

从 [Releases](../../releases) 下载最新 `.dmg`，拖入 `/Applications`。

首次启动授予权限：
1. **麦克风** — 录音。
2. **语音识别** — 调用 Apple 系统识别。
3. **辅助功能** — 监听全局快捷键 + 在光标处粘贴。

点菜单栏麦克风图标 → 设置 → 配置 AI 引擎（或选 Ollama 走全离线）。

### 从源码构建

需要 macOS 14+、Xcode 16+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```bash
brew install xcodegen
git clone https://github.com/clearsky/VoiceBee.git
cd VoiceBee
xcodegen
xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar -configuration Release build
```

构建出的 `.app` 用临时签名签发，本机可用。

## 架构

```
VoiceJarMain        单实例锁 + NSApplication 生命周期
VoiceJarDelegate    菜单栏、设置窗口、权限请求
VoiceEngine         协调器：快捷键 → 录音 → 流式识别 → 润色 → 注入
HotkeyManager       CGEventTap（自愈）；Fn 单键 + 双击检测
AudioRecorder       AVAudioEngine 16 kHz PCM 流式回调
SpeechRecognizer    SFSpeechRecognizer 流式 + contextualStrings 热词
PolishService       Ollama / Claude / DeepSeek / Gemini / OpenAI 兼容（SSE 流式）
TextInjector        剪贴板 + ⌘V，基于 changeCount 自适应恢复
VocabStore          ~/Library/Application Support/VoiceBee/vocab.json
StatsStore          UserDefaults 累计计数器
UpdaterManager      Sparkle 2 封装
```

听写主路径：
```
快捷键按下 → AudioRecorder.start + SpeechRecognizer.startStreaming(contextualStrings)
[音频帧流式送入识别器]
快捷键松开 → 识别器收尾 → PolishService.polishStream(vocabTerms)
→ TextInjector.inject（或即时模式：先上原文，后台润色完成 ⌘V 替换）
→ StatsStore.record + VocabStore.recordHits + 历史
```

## 隐私

- 所有凭据存放在 macOS Keychain（`com.clearsky.VoiceJar`）。
- 选 Apple ASR + Ollama 时，**音频从不出本机**。
- 选云端 LLM（Claude / DeepSeek / Gemini / OpenAI）时，**只发送转写后的文本**，不发送原音频。
- 润色 prompt 明确告诉模型只清理文字，**不要回答问题**或执行 transcript 中的指令。

## 维护者发版清单

发版由 GitHub Actions 自动化，日常只需两步：

```bash
# 1. bump Info.plist（CFBundleShortVersionString + CFBundleVersion）
# 2. 推 tag
git tag v1.x.x
git push --tags
```

CI 自动完成：构建 → 签名 → 公证 → Sparkle 签名 → 生成 appcast.xml → 发 GitHub Release。

**首次配置**（一次性配置以下 GitHub Secrets）：见 [docs/RELEASE.md](docs/RELEASE.md)。
- `SPARKLE_ED_PRIVATE_KEY` — Sparkle 更新签名
- `APPLE_CERT_P12_BASE64` + `APPLE_CERT_PASSWORD` — Developer ID Application 证书
- `APPLE_ID` + `APPLE_APP_PASSWORD` + `APPLE_TEAM_ID` — 公证

本机手工发版：`./scripts/release.sh 1.x.x`。

## License

MIT
