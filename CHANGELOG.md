# Changelog

本项目遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/) 风格；版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added
- 「重复粘贴上次结果」全局快捷键，默认 `⌥⇧V`，可在设置中改键。
- 菜单栏右键加「暂停 / 恢复」开关，暂停时所有全局快捷键放行不拦截，状态持久化。
- CI workflow（`.github/workflows/ci.yml`）：PR 与 push 到 master 自动跑 build + SwiftLint。
- SwiftLint 配置（`.swiftlint.yml`）：起步从宽，opt-in 高价值规则。
- `CHANGELOG.md`、`CONTRIBUTING.md`、Issue / PR 模板。

### Fixed
- OverlayWindow 在多显示器布局下定位错屏：现在用菜单栏屏作 Y 翻转锚点，再用光标实际所在屏 clamp。
- `lastInjectedText` 之前只在 immediate 路径记录，重构到 `TextInjector` 后所有 inject 路径（含 streaming 润色、翻译、历史重粘贴）都自动捕获。
- 修复 `VoiceJarDelegate` 麦克风 / 语音识别授权回调里的 Swift 6 主 actor 隔离 warning。

## [1.2.0] — 2026-05-XX

发版基建首版（CI 自动化 + Sparkle 配置就绪）。详见 GitHub Release notes。

### Added
- 4 档输出风格 + 卡片化设置（受 OpenLess UI 启发）。
- 口述翻译模式 + 工作语言（OpenLess UX 范式）。
- Sparkle 自更新（GitHub Releases + Ed25519 签名）。
- GitHub Actions release workflow（签名 + 公证 + appcast 生成 + release 自动发布）。
- 词典批量管理（多选 + 启用 / 禁用 / 删除）+ 词典导出。
- 历史持久化 + 复制原文 + 重新润色。
- Esc 全链路取消（录音 / ASR / 润色 / 翻译均可中止）。
- 长录音 ASR 会话轮换（绕过 `SFSpeechRecognizer` 60s 限制）。

### Fixed
- 修复口述翻译目标语言 Picker 不可选。
- Sparkle 未配置（`SUPublicEDKey` 为空）时优雅降级，不报错。

## [1.1.0] — 2026-04-XX

### Added
- 词典 / 主页 / Sparkle 自更新基础架构 / 单实例锁。
- 双语 README。
- 新应用图标。

### Removed
- 多余的 entitlements 项。

## [1.0.0] — 2026-03-XX

VoiceJar (VoiceBee) macOS 语音输入工具首版完整存档。
