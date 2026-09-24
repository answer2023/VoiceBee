# VoiceBee 隐私合规 + 网站更新执行计划

> 交接文档,为新会话执行做准备。本文档自包含——包含全部已核实事实、隐私政策草案、要做的工作、决策点、执行顺序。执行者照此推进即可,无需依赖旧会话记忆。
>
> 创建日期:2026-07-04

---

## 〇、一句话背景

VoiceBee v1.3.0 已发布(GitHub latest + Sparkle 自动更新 + 网站下载均正常)。但发现**隐私合规缺口**:网站宣称"语音不上传/本地处理",而默认的 Apple 引擎实际可能把音频上传 Apple 服务器,构成虚假宣传 + 隐私合规风险。需要:①网站文案改合规 + 同步 v1.3.0 功能;②新建隐私政策(网站页 + 软件内 + 首启展示);③为此更新软件代码并发一次新版(v1.3.1)。

**核心策略**:把"隐私"从风险变卖点——不做绝对承诺,而是如实说明"**可选完全本地**"(WhisperKit 本地识别 + Ollama 本地润色 = 全程不出设备),这是真实的、合规的差异化优势。

---

## 执行进度(2026-09-24 更新)

**工作块 B 已完成并随 v1.3.1 发布**(2026-09-24):
- B1 设置「隐私」tab + B2 首启隐私说明页 + B3 Info.plist 权限字符串:commit `f3004fe`;首启窗口加高到 580 使 5 条要点完整可见:`fb6a562`
- B5 发版 v1.3.1(build 11):主仓库 `3c08450` + tag `v1.3.1`;VoiceBee-Releases appcast `7a0b328` + GitHub Release;网站 tangzhihong.com `06ceea8`、jotbee.app `4bca14a`
- **B4 日志脱敏:暂不做**(用户 2026-09-24 决策)— `VoiceEngine` 仍明文记录转写,位置:`$TMPDIR/voicejar_debug.log`(注:上文写的 `/tmp/…` 不准确,实际是 `FileManager.temporaryDirectory`)
- 第四节决策点定稿:① 用网站版政策正文;② App 内展示 = 要点 + 链接网站;③ 首启同意强度 = **仅告知**,不记录同意;④ B4 暂缓;SFSpeech `requiresOnDeviceRecognition` 维持不设
- 已知限制:老用户(`onboardingCompleted` 已为 true)看不到首启隐私页,只能在设置「隐私」tab 查看

### 2026-07-04 进度(工作块 A)

**工作块 A(网站)已全部完成并上线**,每步经 node 计数验证 + 远端 sha 确认:
- **jotbee.app**(`answer2023/jotbee.app`,HEAD `fc08a45`):版本→v1.3.0(hero+更新日志)、功能卡「本地优先」→「本地可选」、隐私区绝对声明→合规披露、功能文案 双模式→四档风格 / 五种→八种语言、meta description 合规、**新增 `privacy.html` 隐私政策独立页**(已填 生效日期 2026-07-05 / 开发者 ClearSky / 邮箱 xtry96@gmail.com;导航链接本就指向 privacy.html,建文件后即生效)。
- **tangzhihong.com**(`answer2023/tangzhihong.com`,HEAD `981032d`):VoiceBee 版本 v1.2.1→v1.3.0、「本地识别」→「可离线识别」。
- **隐私政策 URL**(供 App Store 填报 / 软件内链接用):`https://jotbee.app/privacy.html`

**下一步从工作块 B(软件代码 + 发版 v1.3.1)开始**(见第三节 B1-B5)。软件内隐私入口(B1)可直接链接上面的隐私政策 URL。

**零星未做(可选,低优先)**:jotbee howto 里「双击 Fn 切换即时/润色模式」细节、可选加 WhisperKit 功能卡。

---

## 一、已核实的事实(分析结果,均经代码/命令核实)

### 1.1 完整数据流向

**语音音频(环节1)**
| 引擎 | 音频去向 | 出设备? |
|---|---|---|
| Apple SFSpeech(**当前默认**) | 交 macOS 语音框架,**可能上传 Apple 服务器**(代码未设 `requiresOnDeviceRecognition`) | 可能(到 Apple) |
| WhisperKit(可选) | 本地 Neural Engine/GPU 推理 | 否;唯一网络=首次下载模型 626MB(从 HuggingFace,库内部) |

**文字 - AI 润色/翻译(环节2/3)**
- 发送内容:待处理文字 + 用户工作语言偏好 + **用户词典专名(最多50个)**。
- 发往(取决于用户选的引擎,端点已核实,各1处):
  - Claude → `api.anthropic.com`
  - DeepSeek → `api.deepseek.com`
  - Gemini → `generativelanguage.googleapis.com`
  - OpenAI → `api.openai.com`
  - **Ollama → `localhost:11434`(本地,不出设备)**
- 用用户自己的 API Key 直连,VoiceBee 不中转、不留副本。
- 翻译两个入口:①录音时标记;②选中文字按 ⌥T(模拟 ⌘C 读取选中文字)。

**输出注入(环节4)**:结果写剪贴板 → 模拟 ⌘V → ~3秒后恢复旧剪贴板。纯本地。

**本地存储(均不出设备)**
| 数据 | 位置 | 内容 |
|---|---|---|
| API Key | macOS Keychain(加密) | 各引擎密钥 |
| 历史记录 | `~/Library/Application Support/VoiceBee/history.json` | 转写原文+润色文+时间,最近50条 |
| 词典 | `~/Library/Application Support/VoiceBee/vocab.json` | 专名(但会随润色/翻译上云) |
| 使用统计 | UserDefaults | 字数/时长等 |
| 调试日志 | `/tmp/voicejar_debug.log` | ⚠️ **明文记录转写内容**(隐私点,建议脱敏) |

**数据出设备的出口共三类**:①音频(仅 Apple 引擎→Apple);②文字+词典专名+语言偏好(→云端 LLM,除非本地 Ollama);③模型下载(WhisperKit 首次,不含用户数据)。

### 1.2 隐私合规现状(缺口)

- **Info.plist**:仅 2 条权限告知(`NSMicrophoneUsageDescription`、`NSSpeechRecognitionUsageDescription`),文字简略,**未提数据可能上传第三方**。
- **entitlements**:sandbox 关闭、audio-input 开、network.client 开。
- **首次启动 Onboarding**:**0 处隐私告知/同意**(`OnboardingView.swift` 无任何隐私内容)。
- **网站隐私政策**:**实质不存在**——jotbee.app 无独立 privacy 页面文件;导航"隐私政策"是 `<a href="#privacy">`,但页面无 `id="privacy"` 区块(全页锚点仅 `download`),是**死链**。
- **代码事实**:SFSpeech/WhisperKit 全历史从未设过 on-device 强制(pickaxe 全 0,旧单引擎 `SpeechRecognizer.swift` 亦然)——即"本地"从来不是代码保证,不是这次改动弄坏的。

### 1.3 网站 / 版本现状

- 实际最新发布:**v1.3.0**(GitHub `answer2023/VoiceBee-Releases` latest,含 `VoiceBee-1.3.0.dmg` + `VoiceBee.dmg`,SHA `75b4fdf…`,与本地构建一致)。
- `jotbee.app`(仓库 `answer2023/jotbee.app`,`voicebee.js` 手维护 React.createElement):显示 **v1.2.2**,功能文案停留在旧版(无 WhisperKit/自定义快捷键/词典纠错/四档风格;写着旧"双模式""五种语言")。
- `tangzhihong.com`(仓库 `answer2023/tangzhihong.com`,`app.js`):VoiceBee 显示 **v1.2.1**、JotBee **v1.2.0**;有"本地识别""不上传服务器"标签。
- 下载按钮均走 `releases/latest/download/VoiceBee.dmg`,现指向 v1.3.0,功能正常(此前"点击没反应"是转正 latest 与上传 VoiceBee.dmg 之间的 404 时间窗,已自愈)。

### 1.4 仓库位置速查

| 用途 | 本地路径 | GitHub |
|---|---|---|
| 代码 | `~/Developer/VoiceBee` | `answer2023/VoiceBee`(private) |
| 发布 | `~/Developer/VoiceBee-Releases` | `answer2023/VoiceBee-Releases`(public) |
| 下载页 | `~/Developer/jotbee.app` | `answer2023/jotbee.app` |
| 工作室主页 | `~/Developer/tangzhihong.com` | `answer2023/tangzhihong.com` |

---

## 二、隐私政策草案(待用户最终定稿)

> 以下为草案。非律师定稿,正式发布前建议律师过目。`[方括号]` 需填写。

**VoiceBee 隐私政策**
生效日期:[待定] · 开发者:[ClearSky 工作室 / 主体名称]

VoiceBee 是一款 macOS 语音输入工具,把"数据尽量留在你自己手里"作为设计原则。本政策如实说明处理哪些数据、去了哪里、你如何控制。

**一、核心原则:你可以选择完全本地**
语音识别和 AI 处理均支持完全本地运行。若选 WhisperKit 识别引擎 + 本地 Ollama 润色,你的语音和文字全程不离开这台 Mac。是否联网、用哪个引擎,由你在设置中决定。

**二、语音音频的处理**
- WhisperKit 引擎:本地识别,音频不上传;首次使用需联网下载模型(约 626MB),之后完全离线。
- Apple 语音识别引擎:调用 macOS 系统服务,音频可能被发送到 Apple 服务器,受 Apple 隐私政策约束,是否本地由系统决定。
- VoiceBee 本身没有服务器,不接收/存储/转发任何音频。

**三、文字的处理(AI 润色/翻译)**
使用时会把「待处理文字 + 常用语言 + 词典专名」发送给你自己配置的 AI 服务:云端服务(Claude/DeepSeek/Gemini/OpenAI 兼容)受其各自隐私政策约束;本地 Ollama 则不上传。使用你自己的 API 密钥直连,VoiceBee 不中转、不留副本。

**四、数据存储(均在本地)**
API 密钥存 macOS 钥匙串(加密);历史记录最近 50 条存应用支持目录,可随时清空;词典/统计存本地。不上传、不备份。

**五、权限说明**
麦克风(录音)、语音识别(Apple 引擎转文字)、辅助功能(读取选中文字、注入结果)。

**六、我们不做的事**
不上传音频/文字到 VoiceBee 服务器(无服务器);无广告、无追踪、不出售数据;无需账号。

**七、儿童隐私**:不面向 14 岁以下儿童。
**八、政策变更**:更新将在本页公布。
**九、联系我们**:[邮箱]

---

## 三、要做的工作(4 块)

### 工作块 A:网站更新(纯文案,不发版)

**A1. 新建隐私协议独立页面**
- jotbee.app 新建隐私协议页面/区块,放定稿协议正文;
- 修复导航 `#privacy` 死链(建加 `id="privacy"` 区块或独立 privacy.html)。

**A2. 功能同步 + 合规措辞**
- `jotbee.app/voicebee.js`:
  - 版本号 v1.2.2 → v1.3.0(hero 3处 + 更新日志加 v1.3.0 条目);
  - 功能:补 WhisperKit 引擎、可自定义快捷键、词典专名纠错、四档输出风格;
  - 改:「双模式」→「四档输出风格(原文/轻润色/结构化/正式)」;「双击 Fn 切换」→「可自定义快捷键(单键/组合,按住/切换)」;「五种语言」→「八种语言」;
  - 合规措辞(见下方"措辞定稿")。
- `tangzhihong.com/app.js`:
  - VoiceBee 版本 v1.2.1 → v1.3.0;
  - 隐私标签"本地识别""不上传服务器"→ 合规版。

**A2 合规措辞定稿**(替换绝对化声明):
| 位置 | 原(不合规) | 改为(合规) |
|---|---|---|
| 隐私区大标题 | 你的声音不会被上传 | 语音可完全在本地处理 |
| 隐私区正文 | 语音识别基于 Apple 本地框架,不经过第三方服务器 | 选用 WhisperKit 引擎时,语音完全在本地处理;该引擎首次使用需联网下载模型,之后完全离线运行。选用 Apple 语音识别时,音频由 Apple 系统服务处理(受 Apple 隐私政策约束)。AI 润色和翻译使用你自己的 API Key,仅发送文字,费用透明。 |
| 功能卡「本地优先」 | 本地优先 | 本地可选 |
| meta「数据本地处理」 | …数据本地处理。 | …支持完全本地识别。 |
| tangzhihong 标签「本地识别」 | 本地识别 / 不上传服务器 | 可离线识别 |

### 工作块 B:软件代码更新(要发版 v1.3.1)

- **B1. 软件内隐私协议入口**:设置界面加"隐私政策"入口。涉及 `VoiceJar/Views/SettingsView.swift`。
- **B2. 首启展示隐私协议 + 同意**:Onboarding 加一屏(协议要点 + 数据流向 + 同意)。涉及 `VoiceJar/Views/OnboardingView.swift`(当前 0 隐私内容)。
- **B3. Info.plist 权限字符串增强**:麦克风/语音识别用途补"数据可能上传"告知。涉及 `VoiceJar/Info.plist`。
- **B4. 调试日志脱敏**:`/tmp/voicejar_debug.log` 不再明文记录转写正文。涉及 `VoiceJar/Services/Logger.swift` / `VoiceEngine.swift` 的 log 调用(如 `📝 当前文本: \(rawText)`、`✅ 翻译结果: \(finalText)`)。
- **B5. 构建 + 发版 v1.3.1**:改 Info.plist 版本(1.3.0→1.3.1,build 10→11)→ `scripts/release.sh 1.3.1` → 更新 `VoiceBee-Releases/appcast.xml` + GitHub release → 同步网站版本号。发版细节见项目根 `CLAUDE.md` 和 `docs/RELEASE.md`。

---

## 四、决策点

**已定(用户认可)**:
- 保留"隐私"作为核心卖点,走"可选完全本地"口径;
- 隐私协议要:网站独立页 + 软件内入口 + 首启展示;
- 要改代码 + 发新版;
- 网站先做,代码 + 发版新会话做。

**待最终确认(执行时和用户敲定)**:
1. 隐私协议正文(上方草案是否直接用/微调);
2. 软件内展示方式——**建议**:app 内放核心要点 + "查看完整政策"链接到网站页(离线可见要点 + 完整版可更新);
3. 首启同意强度——**建议**:明确"同意"才能用(PIPL 对敏感信息倾向明确同意);
4. 日志脱敏(B4)是否此次一起做——**建议**:一起;
5. tangzhihong.com 是否也加隐私入口——**待定**(隐私页主放 jotbee 即可)。

---

## 五、建议执行顺序

1. **定稿隐私协议**(第四节决策点1);
2. **工作块 A(网站)**:A1 隐私页 + 修死链 → A2 功能同步 + 合规措辞(jotbee + tangzhihong)。纯文案、法律止血最急、见效快;
3. **工作块 B(代码)**:B1 设置入口 → B2 首启同意 → B3 Info.plist → B4 日志脱敏;统一 build 验证;
4. **B5 发版 v1.3.1**:release.sh → appcast → GitHub release → 网站版本号收尾。

---

## 六、执行时的操作纪律(重要)

- **每步写操作后立即用独立命令验证真实落盘**(`git status` / `git ls-remote` 远端 sha / `Read` 文件),不凭"写成功"回执断定;
- 网站两个仓库分别 commit/push,各自验证远端 sha 前进;
- 代码改动改一处 build 一次;发版严格按 `docs/RELEASE.md` 双仓库手动流程;
- 隐私措辞任何改动,先贴 diff 给用户确认再落地(法律敏感)。

---

## 七、遗留提醒

- v1.3.0 未公证,新用户浏览器下载需右键→打开(既有状态)。
- WhisperKit 与 SFSpeech 共享 audioProcessor 在极端快速停-启下有麦克风竞争(已加 session token 缓解,根治需串行化,低优先)。
- 代码层"SFSpeech 是否设 requiresOnDeviceRecognition = true / 默认引擎是否切 WhisperKit"是**产品决策**,影响隐私口径能多强,可与 B 块一起讨论(不设=保持"可选本地"口径;设了=可更强调本地)。
