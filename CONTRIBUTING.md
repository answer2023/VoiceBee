# Contributing to VoiceBee

感谢你想为 VoiceBee 出力！下面这些约定能让你的 PR 顺利合入。

## 环境要求

- macOS 14 或更新（应用 deployment target = 14.0）
- Xcode 16.3+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）
- [SwiftLint](https://github.com/realm/SwiftLint)（`brew install swiftlint`）

## 起步

```bash
git clone https://github.com/answer2023/VoiceBee.git
cd VoiceBee
xcodegen                    # 由 project.yml 生成 .xcodeproj
open VoiceJar.xcodeproj
```

> **重要**：`VoiceJar.xcodeproj/project.pbxproj` **是签入 git 的**，但 `project.yml` 才是真源。新增 / 删除 / 移动 Swift 文件时只改 `project.yml` 然后 `xcodegen`，**不要直接编辑 pbxproj**——会被下次 xcodegen 覆盖。

## 项目结构速查

```
VoiceJar/
├── Models/         # AppState、Vocab、Stats、PolishSettings、OutputStyle、TranslationSettings
├── Services/       # AudioRecorder、SpeechRecognizer、HotkeyManager、PolishService、TextInjector、UpdaterManager、VoiceEngine、Logger
├── Views/          # SwiftUI 视图（菜单栏 / 设置 / 历史 / 浮窗 / 引导）
├── VoiceJarDelegate.swift   # AppDelegate + main entry
├── Info.plist
└── VoiceJar.entitlements
```

`VoiceEngine` 是流程中枢，串起录音 → 实时识别 → 润色 → 注入。改全局行为通常从这里开始读。

## 开发流程

1. **Fork 并新建分支**：`git checkout -b feat/your-feature`。
2. **本地验证**：
   ```bash
   xcodegen
   xcodebuild -project VoiceJar.xcodeproj -scheme VoiceJar \
     -configuration Debug -destination 'platform=macOS' \
     CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO clean build
   swiftlint
   ```
3. **手动测试**：至少跑一遍核心流程（按住 Fn → 说话 → 松开 → 文本是否正确注入）。
4. **提 PR**：标题用约定式前缀（`feat:` / `fix:` / `docs:` / `refactor:` / `chore:`），描述见 PR 模板。

## 代码风格

- **Swift 6 strict concurrency** 已启用。新代码尽量 actor-isolated 清楚；跨 actor 调用用 `Task { @MainActor in ... }` 显式 hop。
- 遵守 SwiftLint 规则（`.swiftlint.yml`）；CI 会自动跑。
- 新增功能附带 `Logger` 调用，方便 `voicejar_debug.log` 追问题。
- 用户可见文案优先简体中文（项目主语言）；代码注释中英文都可以，但**为什么这么做**比**做了什么**更值得写。

## 提交规范

- 每个 commit 聚焦一件事。`amend` 比堆 fixup commit 好。
- 提交信息首行用约定式前缀，body 解释**为什么**：

  ```
  feat(hotkey): paste-last 快捷键

  存的 lastInjectedText 之前只在 immediate 路径写入；
  下沉到 TextInjector 让所有 inject 路径自动捕获，
  避免 streaming / translation 路径漏更新。
  ```

## 报告 bug / 提功能

走 GitHub Issues，对应模板：
- **Bug**：附 `~/Library/Containers/com.clearsky.VoiceJar/Data/tmp/voicejar_debug.log` 末段日志、复现步骤、macOS 版本。
- **Feature**：先描述用户场景再描述方案（用户问题往往比初次设想的方案更有价值）。

## 发版流程（仅维护者）

1. 在 `project.yml` 或 Info.plist 里 bump `CFBundleShortVersionString` 与 `CFBundleVersion`。
2. 更新 `CHANGELOG.md` 的 `[Unreleased]` 段，加新版号 heading。
3. `git tag v1.x.y && git push --tags` —— `release.yml` 自动构建签名公证 + 生成 appcast.xml + 创建 GitHub Release。
4. Sparkle 客户端从 `appcast.xml`（release asset）拉新版。

## 行为准则

对所有人友善。技术异议归技术异议，对人不带情绪。
