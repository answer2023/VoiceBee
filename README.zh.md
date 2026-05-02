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

每次打包 `.dmg` 上传 Releases 前的检查清单：

### 一次性配置（仅第一次发版）

- [ ] **生成 Sparkle ed25519 密钥对**
  ```bash
  find ~/Library/Developer/Xcode/DerivedData -name "generate_keys" -type f -path "*Sparkle*" | head -1
  # 跑上面打印出的路径
  ```
  私钥自动存入 macOS Keychain（service 为 `https://sparkle-project.org`），公钥打印到屏幕。
- [ ] **把公钥贴进 `VoiceJar/Info.plist`** 作为 `SUPublicEDKey` 的值。
- [ ] **导出私钥给 CI 用**：
  ```bash
  /path/to/generate_keys -x /tmp/sparkle_priv.key
  cat /tmp/sparkle_priv.key   # 复制
  rm /tmp/sparkle_priv.key    # 立刻删除
  ```
  到 GitHub repo → Settings → Secrets → Actions 新增 `SPARKLE_ED_PRIVATE_KEY`。**永远不要 commit、截图、转发这个私钥** —— 一旦泄漏，攻击者就能签发被所有 VoiceBee 用户静默自动安装的恶意更新。
- [ ] **更新 `SUFeedURL`** 为你真实的 appcast URL（默认 `releases/latest/download/appcast.xml`）。
- [ ] **Apple 开发者证书 + 公证（notarization）** — 与 Sparkle 签名互不相同，是让 macOS Gatekeeper 接受 `.app` 的必备条件。

### 每次发版

- [ ] 在 `VoiceJar/Info.plist` 里 bump `CFBundleShortVersionString` 和 `CFBundleVersion`。
- [ ] `xcodegen && xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar -configuration Release build`。
- [ ] 打包 `VoiceBee-<version>.dmg`，跑 `xcrun notarytool submit` 公证。
- [ ] 用 Sparkle 给 DMG 签名：
  ```bash
  ./sign_update VoiceBee-<version>.dmg
  # 输出：sparkle:edSignature="..." length="..."
  ```
- [ ] 更新 `appcast.xml`，把新的 `<enclosure>`（含 `sparkle:edSignature` 和 `sparkle:version`）写进去。
- [ ] 打 tag：`git tag v<version> && git push --tags`。
- [ ] 把 `.dmg` + `appcast.xml` 上传到 GitHub Release。
- [ ] 冒烟测试：装旧版 → 点"检查更新" → 走完整自动更新链路验证通过。

## License

MIT
