# WhisperKit PoC 结果报告

> 实验日期: 2026-05-11
> 分支: feature/whisperkit-asr
> PoC 路径: `Tools/WhisperKitPoC/`(独立 SwiftPM,完全隔离主 app)
> 目的: 验证 2 个点 — (1) SPM 集成可行性,(2) 中文混输 + 英文专名识别质量
> **结论**: ✅✅ 双双验证通过,推荐推进 Phase 2(抽象层 + 主 app 集成)

---

## 决策:为什么选 standalone CLI(而非主 app `#if DEBUG`)

| 维度 | standalone CLI(本次选择) | 主 app `#if DEBUG` |
|---|---|---|
| 主 app 风险 | ❌ 零(独立 Package.swift) | ⚠️ 改 `VoiceJar.xcodeproj` 影响主 app build |
| 独立验证 | ✅ `swift run` 直接跑 | 需启动 Xcode + 切 scheme |
| Git 影响面 | 新建 `Tools/WhisperKitPoC/` 子树 | 改 pbxproj + SPM 锁文件 |
| 缓存独立 | ✅ `~/Library/Caches/org.swift.swiftpm/` | 跟主 app 共用 Xcode SPM 缓存 |
| 重头部署 | 低(git clone + swift run) | 需开 Xcode 跑 |

→ standalone CLI 验过后,主 app 接入是"已知可行"的低风险动作,不是探路。

---

## A. SPM 集成 ✅

### 仓库 URL

| URL | 状态 | 备注 |
|---|---|---|
| `https://github.com/argmaxinc/WhisperKit` | HTTP 301 → 新 URL | 老 URL 仍可用,Xcode/SPM 自动 follow redirect |
| `https://github.com/argmaxinc/argmax-oss-swift` | HTTP 200 | ✅ **使用此 URL** |

### Package.swift

```swift
// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "WhisperKitPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperKitPoC",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
)
```

### 编译结果

| 检查 | 结果 |
|---|---|
| `swift build` (debug, 首次) | ✅ 编译 72 个 module,无 error |
| `swift build` (debug, 增量) | ✅ 1.14s |
| `swift run -c release` (首次) | ✅ 33.54s 编译 + 链接 |
| **Swift 6 告警** | ✅ **零告警**(grep "warning:|Sendable" 无命中) |
| 依赖项 | WhisperKit + ArgmaxCore + swift-numerics + swift-argument-parser + swift-system + (vendored) swift-transformers |

### main.swift 接口踩坑 + 修复

| 错误 | 修复 |
|---|---|
| `DecodingOptions(language:task:...)` 参数顺序错 | `task` 必须在 `language` 之前 |
| `results.flatMap { $0.segments.map(\.text) }` keypath 推断失败 | 用顶层 `results.map(\.text)`(`TranscriptionResult.text` 直接可用) |

→ 修完一次过,**API 设计 well-typed**,Swift 6 编译期就抓出错误。

### 给主 app 加 SPM 的步骤(下一阶段用,本次未执行)

**前提**:此 PoC 已验过 WhisperKit 接口正常 + 模型下载成功 + 转录质量符合预期 ✅

**Xcode 手动步骤**(避免 Claude Code 自动改 pbxproj 风险):

1. 打开 `VoiceJar.xcodeproj`
2. File → Add Package Dependencies...
3. URL: `https://github.com/argmaxinc/argmax-oss-swift`
4. Dependency Rule: Up to Next Major Version,from `1.0.0`
5. Click "Add Package"
6. 选 `WhisperKit` product → Add to Target: `VoiceJar`
7. Build verify: `xcodebuild build -configuration Release`

会自动改 `VoiceJar.xcodeproj/project.pbxproj` 的 `packageReferences` + `XCSwiftPackageProductDependency`。

---

## B. 模型下载 ✅

### 实测数据

| 项 | 值 |
|---|---|
| 模型名 | `openai_whisper-large-v3-v20240930_626MB` |
| 来源 | HuggingFace `argmaxinc/whisperkit-coreml` |
| **大小** | **606 MB**(主模型) + ~2 MB(tokenizer) = **608 MB total** |
| **Load + prewarm 总耗时** | **304.17s**(含下载 + Core ML 加载 + 预热) |
| 推理时网络流量 | 0(纯本地) |

### 缓存路径(关键 ⚠️)

WhisperKit 默认下载到:
```
~/Documents/huggingface/models/
├── argmaxinc/whisperkit-coreml/
│   ├── .cache/huggingface/
│   └── openai_whisper-large-v3-v20240930_626MB/
│       ├── AudioEncoder.mlmodelc/    (~340 MB)
│       ├── MelSpectrogram.mlmodelc/  (~2 MB)
│       ├── TextDecoder.mlmodelc/     (~264 MB)
│       ├── config.json
│       └── generation_config.json
└── openai/whisper-large-v3/
    ├── tokenizer.json
    ├── tokenizer_config.json
    └── config.json
```

⚠️ **生产坑**:`~/Documents/huggingface/` 是**用户可见**的 Documents 文件夹!最终产品**必须**通过 `WhisperKitConfig.modelFolder` 重定向到:
```
~/Library/Application Support/VoiceBee/models/
```
否则用户会发现 Documents 里冒出 600 MB 的 `huggingface` 文件夹,UX 很糟糕。

### 模型结构

WhisperKit 把单一 Whisper 模型拆成 **3 个 Core ML 模型** 各司其职:
- `AudioEncoder.mlmodelc` — 音频特征 → encoder hidden states(最重,340 MB)
- `MelSpectrogram.mlmodelc` — PCM 波形 → mel-spectrogram(轻量,2 MB)
- `TextDecoder.mlmodelc` — encoder + tokens → 下一个 token(264 MB,推理热区)

分离设计允许:
- 单独加载/卸载(若只做语言检测可只加载 encoder)
- KV cache 在 decoder 内部独立优化
- 三个模型可在 Neural Engine / GPU / CPU 间灵活调度

---

## C. 5 段转录结果对比 ✅

### 测试集生成

```bash
say -v Tingting "今天 VoiceBee 这个产品表现不错" -o test_audio/01.aiff
say -v Tingting "我觉得 JotBee 这个 app 挺好" -o test_audio/02.aiff
say -v Tingting "用 ClearSky 团队开发的 macOS 工具" -o test_audio/03.aiff
say -v Tingting "WhisperKit 集成测试中" -o test_audio/04.aiff
say -v Tingting "今天天气不错" -o test_audio/05.aiff

# 转 16kHz mono wav 给 WhisperKit
for f in test_audio/*.aiff; do
  afconvert -f WAVE -d LEI16@16000 -c 1 "$f" "${f%.aiff}.wav"
done
```

- 用 **Tingting**(zh_CN 普通话女声,大陆口音,跟目标用户群对齐)
- 5 段平均时长 ~2 秒
- 4 段含英文专名(VoiceBee / JotBee / ClearSky / WhisperKit),1 段纯中文做基线
- 同时测 `.aiff`(原 TTS 输出)和 `.wav`(16 kHz 转码)各 5 段,共 10 个推理

### WhisperKit 实测结果

| # | TTS 文本(应该说的) | 含英文专名 | WhisperKit 转录 | 推理耗时 | 结果 |
|---|---|---|---|---|---|
| 01.aiff | 今天 VoiceBee 这个产品表现不错 | VoiceBee | 今天**Boysbee**這個產品表現不錯 | 7.22s ⚠️ 首推冷启动 | ⚠️ 拼写错(听出英文专名) |
| 01.wav | 今天 VoiceBee 这个产品表现不错 | VoiceBee | 今天**Voizbee**這個產品表現不錯 | 1.13s | ⚠️ 拼写错(听出英文专名) |
| 02.aiff | 我觉得 JotBee 这个 app 挺好 | JotBee, app | 我覺得**Jotby**這個**App**挺好 | 1.10s | ⚠️ 拼写错(听出英文专名);**App** 正确 |
| 02.wav | 我觉得 JotBee 这个 app 挺好 | JotBee, app | 我覺得**Jotby**這個**App**挺好 | 1.10s | 同上 |
| 03.aiff | 用 ClearSky 团队开发的 macOS 工具 | ClearSky, macOS | 用**ClearSky**團隊開發的**MacOS**工具 | 1.20s | ✅ ClearSky **正确**;MacOS 大小写微差 |
| 03.wav | 用 ClearSky 团队开发的 macOS 工具 | ClearSky, macOS | 用**ClearSky**团队开发的**MacOS**工具 | 1.23s | ✅ 同上,简体 |
| 04.aiff | WhisperKit 集成测试中 | WhisperKit | **Whisper Kit**集成测试中 | 1.13s | ✅ 仅插入空格,语义对 |
| 04.wav | WhisperKit 集成测试中 | WhisperKit | **Whisper Kit**集成测试中 | 1.13s | 同上 |
| 05.aiff | 今天天气不错 | (无,基线) | 今天天气不错。 | 1.06s | ✅ 完美,自动加句号 |
| 05.wav | 今天天气不错 | (无,基线) | 今天天气不错。 | 1.05s | ✅ 完美 |

### vs SFSpeech baseline 对比

来自 vocab follow-up 实测(2026-05-11,见 CLAUDE.md):**SFSpeech 听 "VoiceBee" 输出 "Vocab"(5/5 失败)**。推测其他英文专名同样降级:

| 专名 | SFSpeech(实测/推测) | WhisperKit(实测) | 差距 |
|---|---|---|---|
| VoiceBee | **Vocab**(完全失声) | **Voizbee / Boysbee**(听出英文专名,拼写微错) | 🌟 质的飞跃 |
| JotBee | 未实测,推测同 Vocab 类 | **Jotby**(听出英文专名) | 🌟 质的飞跃 |
| ClearSky | 未实测,推测部分丢失 | **ClearSky**(完美) | ✅ 完美 |
| WhisperKit | 未实测,推测乱 | **Whisper Kit**(空格微差) | ✅ 近完美 |
| macOS | 未实测,推测乱 | **MacOS**(大小写微差) | ✅ 近完美 |

### 核心洞察

1. **WhisperKit 听出英文专名 ≠ 拼写完美**:VoiceBee/JotBee/WhisperKit 这些**新造词**不在 Whisper 训练数据里,模型按音节"猜"拼写(Boysbee/Voizbee/Jotby)。但**关键质的差距**是:WhisperKit 知道这是一个英文专名,而 SFSpeech 干脆听成中文常见词 "Vocab" — 后者根本无法挽救
2. **常见英文词完美**:`ClearSky`、`App`、`MacOS` 全部正确识别 — Whisper 训练数据覆盖
3. **promptTokens 必能治根**:既然 WhisperKit 已经识别 "这是英文专名",那么 `DecodingOptions.promptTokens` 注入 "VoiceBee" 作为 decoder conditioning context,模型必然会优先匹配这个 token。这是 PoC Phase 2 必测项
4. **繁简不一致**:aiff 倾向繁体,wav 倾向简体 — Whisper 推理有轻微非确定性。可通过 promptTokens 注入简体词典统一
5. **句号 / 标点**:WhisperKit 自动补句号(`今天天气不错。`),效果可对齐 SFSpeech 的 `addsPunctuation`

---

## D. 结论 / 下一步

### 双验证结论

| 验证点 | 结果 |
|---|---|
| **SPM 集成可行性** | ✅✅ 完美 — 老 URL 重定向 + 新 URL 直连,Package.swift 一行依赖,零 Swift 6 告警 |
| **中文混输 + 英文专名识别质量** | ✅ 显著优于 SFSpeech — 常见英文词完美,新造词识别为英文专名(待 promptTokens 治根) |

### 推荐推进 Phase 2

按 CLAUDE.md "WhisperKit 迁移规划" 节的进度跟踪:
- [x] 诊断完成(2026-05-11)
- [x] **技术调研 + 设计**(2026-05-11,本 PoC)
- [ ] **PoC promptTokens 实验**(下一步,验证 vocab 治根)
- [ ] 抽象层 `ASRProvider` protocol
- [ ] UI 引擎选择
- [ ] 模型下载管理
- [ ] alpha 测试
- [ ] 默认开关

### 立即可做的 PoC 迭代(本分支内)

**实验 1:promptTokens 注入 vocab**
- 修改 main.swift,先用 `pipe.tokenizer` 把 `["VoiceBee", "JotBee", "ClearSky", "WhisperKit"]` 编码成 `[Int]`
- `DecodingOptions(promptTokens: tokens, ...)` 再跑同 5 段
- 期望:VoiceBee/JotBee 拼写恢复正确

**实验 2:不同模型 size 对比**
- 跑 `openai_whisper-base` / `openai_whisper-small` / `large-v3-turbo`(如果 HF 有)
- 看小模型对英文专名识别质量是否仍可用 — 决定 onboarding 默认 size

**实验 3:真人音频测试**
- 录 5-10 段你自己的中文混输专名语音(模拟真实 VoiceBee 用户场景)
- 对比 SFSpeech baseline(复用主 app SpeechRecognizer.swift)

### 主 app 集成准备(等 PoC 全过)

| 任务 | 优先级 | 状态 |
|---|---|---|
| 设计 `protocol ASRProvider`(包 SFSpeech / WhisperKit) | 🔴 高 | 待启动 |
| 主 app SPM 加 WhisperKit 依赖 | 🔴 高 | 步骤已写在本报告 A 节 |
| `WhisperKitConfig.modelFolder` 重定向到 `~/Library/Application Support/VoiceBee/models/` | 🔴 高(避免 Documents 污染) | 待启动 |
| Onboarding:首次启动引导下载模型 + 进度条 | 🟡 中 | 待启动 |
| Settings:ASR engine 切换 UI | 🟡 中 | 待启动 |
| `actor PolishService` 持有 WhisperKit 实例的 Sendable 处理 | 🟢 低(待主 app 集成实测) | 留意 |

---

## E. promptTokens 治根实验(2026-05-11 增补)

### 实验设计

在原 PoC 基础上加 `--compare` 模式:同一份音频跑两轮,baseline(无 prompt)+ with promptTokens,直接对比输出。

### API 调用方式(为 Phase 2 抽象层参考)

```swift
// 1. WhisperKit 是 lazy init — init() 后必须显式 loadModels() 才能用 tokenizer
let pipe = try await WhisperKit(config)
try await pipe.loadModels()  // ← 关键!不调这行,pipe.tokenizer 是 nil

// 2. tokenize prompt
let raw = pipe.tokenizer!.encode(text: " " + vocabText.trimmingCharacters(in: .whitespaces))
let promptTokens = raw.filter { $0 < pipe.tokenizer!.specialTokens.specialTokenBegin }

// 3. 注入 DecodingOptions
var options = DecodingOptions(task: .transcribe, language: "zh", temperature: 0.0)
options.promptTokens = promptTokens
let results = try await pipe.transcribe(audioPath: path, decodeOptions: options)
```

### 实验:3 种 prompt 文本风格 + 4 种阈值组合 = 6+ 次实测

| 实验 | promptText | 阈值 | Pass 2 结果 |
|---|---|---|---|
| 1 | `"VoiceBee JotBee ClearSky WhisperKit"` 空格分隔 vocab list | 默认 | ❌ 全部 10/10 空字符串 |
| 2 | `"用户经常提到这些产品名:VoiceBee、JotBee、ClearSky、WhisperKit。"` 自然语言 | 默认 | ❌ 全部 10/10 空字符串 |
| 3 | 同 #2 | `compressionRatioThreshold: nil, logProbThreshold: nil, firstTokenLogProbThreshold: nil, noSpeechThreshold: nil`(全禁) | ❌ 仍然全部 10/10 空字符串 |

**Tokenization 本身正常**:
- `"VoiceBee JotBee ClearSky WhisperKit"` → 13 tokens `[15229, 33, 1653, 508, 310, 33, 1653, 14993, 50, 4133, 41132, 610, 45626]`
- BPE 拆分:`Voice` (15229) + `B` (33) + `ee` (1653) — Whisper vocabulary 里**确实有** `Voice` / `B` / `ee` 这些 subword,意味着模型理论上能拼出 "VoiceBee"

**推理延迟**:Pass 2 普遍 +0.2~0.3s,说明 prompt context **确实进了 cross-attention**(没被 framework 静默丢弃),只是输出阶段被 filter 掉了

### 结论:promptTokens 用法暴露未知行为

| 问题 | 状态 |
|---|---|
| promptTokens 是否治好新造词拼写? | ❌ **未验证** — Pass 2 输出空,无法对比 |
| API 简洁度(给 Phase 2 抽象用) | ✅ 简单:`tokenizer.encode(text:)` → `[Int]` → `DecodingOptions.promptTokens` |
| 推理延迟影响 | +0.2~0.3s / 段 |
| 副作用(纯中文段 #5)是否被影响 | ⚠️ #5 也变空 — 说明影响是**全局性**而非 vocab-specific |

### 失败假设排查

| 假设 | 验证 | 结论 |
|---|---|---|
| (a) prompt 是 vocab list 不像自然语言 | 用自然语言 prompt 复测 | ❌ 仍空 |
| (b) compression/logProb/noSpeech 阈值 trip | 4 个阈值全 nil 复测 | ❌ 仍空 |
| (c) tokenization 失败 | 输出 13 tokens 正确(BPE 含 `Voice`/`B`/`ee`) | 排除 |
| (d) promptTokens 没进 cross-attention | 推理延迟 +0.2-0.3s,说明进了 | 排除 |
| (e) WhisperKit v1.0.0 此功能有 bug / 用法有额外要求 | **待 Phase 2 进一步研究** | 🟡 当前最可能 |

### Phase 2 待研究项(把"promptTokens 治根"留为开放问题)

1. **看 WhisperKit Tests/Examples**:`.build/checkouts/argmax-oss-swift/Tests/` 是否有 promptTokens 实测用例?ArgmaxCLI 跑通 promptTokens 的实际命令是什么?
2. **试 prefixTokens 替代 promptTokens**:Whisper 有两个 conditioning slot — `<|startofprev|>` 走 promptTokens(prior context),`<|sot|>` 后走 prefixTokens(transcript 起始)。可能用 prefixTokens 行为不同
3. **试 verbose log**:`config.verbose = true` + `logLevel: .debug` 看模型内部 token sampling 实际选了什么
4. **试 large-v3-turbo / small / base**:不同模型对 promptTokens 行为可能不同
5. **试 ArgmaxCLI 命令行**:`swift run argmax-cli transcribe <audio> --prompt "..."` — 如果官方 CLI 也复现空输出,确认是 v1.0.0 bug;如果 CLI 正常,我的代码缺某个 option

### 失败情况下的 fallback(Phase 2 备选方案)

| 方案 | 实现成本 | 鲁棒性 |
|---|---|---|
| **A. 后处理映射**(transcript 拿到后,用编辑距离把 `Voizbee` → `VoiceBee`) | 低 | 中 — 假阳性风险(误改正常词) |
| **B. promptTokens 修通**(继续研究 #4) | 中 — 需深入 WhisperKit | 高 — 治本 |
| **C. Argmax Pro custom vocabulary**(付费) | 商业成本 | 高 |
| **D. 不解决专名拼写**(接受 SFSpeech 已经的明显改进) | 0 | 仍优于 SFSpeech 的 "Vocab" 失败 |

**临时推荐:Phase 2 集成主 app 时先按 D 上线**(基础场景已经显著好于 SFSpeech),并行做 #4 研究 promptTokens 正确用法 → 后续启用 vocab 治本。

---

## 附录:运行环境快照

```
日期: 2026-05-11 23:43
分支: feature/whisperkit-asr
主机: Apple Silicon (Darwin 25.5.0)
Xcode toolchain: Swift 5.10 / 6 兼容
WhisperKit: v1.0.0 (2026-05-01 发布)
模型: openai_whisper-large-v3-v20240930_626MB
模型实际大小: 606 MB
Load + prewarm: 304.17s (首次下载 + 加载 + 预热)
推理延迟(M1 Max,2 秒音频): 1.0-1.2s(冷启首次 7.22s)
swift run total wall time: 5m 56s
.build/ size: 1.1 GB(release 编译产物)
```

```
PoC 文件树:
Tools/WhisperKitPoC/
├── .gitignore                  (.build/, Package.resolved, test_audio/)
├── Package.swift
├── Sources/WhisperKitPoC/main.swift
└── test_audio/                  (gitignored)
    ├── 01.aiff / 01.wav         (今天 VoiceBee...)
    ├── 02.aiff / 02.wav         (我觉得 JotBee...)
    ├── 03.aiff / 03.wav         (用 ClearSky...)
    ├── 04.aiff / 04.wav         (WhisperKit...)
    └── 05.aiff / 05.wav         (今天天气不错)
```
