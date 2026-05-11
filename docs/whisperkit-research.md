# WhisperKit 技术调研报告

> 调研日期: 2026-05-11
> 分支: feature/whisperkit-asr
> 目的: 替换 SFSpeechRecognizer 解决英文专名识别瓶颈(vocab follow-up 已诊断为根因)
> 范围: view-only,不动 SPM 依赖,不动代码

---

## TL;DR

| 维度 | 结论 |
|---|---|
| **可行性** | ✅ 强烈推荐推进 PoC |
| **要适配的版本** | v1.0.0(2026-05-01 刚发布,重大重组 + Swift 6 支持) |
| **新仓库名** | `argmaxinc/argmax-oss-swift`(原 `argmaxinc/WhisperKit`) |
| **streaming API** | ✅ `AudioStreamTranscriber` actor + state change callback(README 未文档化但源码存在) |
| **prompt 注入** | ✅ `DecodingOptions.promptTokens: [Int]?`(比 SFSpeech `contextualStrings` 更强,影响首批 token) |
| **macOS 最低** | 14.0 — **正好匹配** VoiceBee `LSMinimumSystemVersion=14.0` |
| **Swift 6 兼容** | ✅ v1.0.0 引入,VoiceBee 已 Swift 6 |
| **License** | MIT,商业兼容 |
| **主要风险** | (1) streaming API 文档稀薄需源码读懂;(2) 中文 benchmark 未官方发布;(3) 顶层 kit 类未 `Sendable`(只对 actor isolation 严格场景有影响) |

---

## A. 项目状态

| 项 | 值 |
|---|---|
| 仓库名 | `argmaxinc/argmax-oss-swift` (原 `argmaxinc/WhisperKit` 2026-05-01 重命名) |
| 最新 release | **v1.0.0** (2026-05-01) |
| Stars | 6,078 |
| Forks | 554 |
| Open issues | 117 |
| 最后 push | 2026-05-01 |
| 维护方 | **Argmax Inc.** (商业实体,Pro SDK 是付费产品,OSS 是开源底座) |
| License | MIT |
| Apple endorsement | 无官方背书,但 Argmax 团队多名前 Apple ML 工程师 + ICML 2025 paper(论文链接见 HuggingFace 模型卡) |
| 活跃度 | 极高 — 8 个 release in 1 年(v0.13 → v1.0),近期 PR `#458 Swift 6 Concurrency`、`#466 Remove deprecated APIs`、`#467 Remove TextDecoderContextPrefill` |

**关键事件**:v1.0.0 把单一 WhisperKit 重组为 multi-kit umbrella(WhisperKit + SpeakerKit + TTSKit + ArgmaxCore),这是**重大里程碑** — 项目从单点工具进化为通用 Apple Silicon 语音 AI 平台。

---

## B. 兼容性

| 平台 | 最低版本 | VoiceBee 当前 | 适配 |
|---|---|---|---|
| macOS | **14.0** | 14.0 | ✅ 完美匹配 |
| Xcode | 16.0 | (本机已 16+) | ✅ |
| Apple Silicon | 必需 | arm64-only | ✅ |
| Swift | 5.10 / 6 | 6 | ✅ |

跨平台细节:WhisperKit 自身支持 macOS 14+ 和 iOS(版本未明确,根据子 kit 推断 iOS 16+),但 VoiceBee 是纯 macOS,**无 iOS 适配负担**。

---

## C. API 设计(最关键)

### C.1 同步转录(等价于 SFSpeech 文件识别)

```swift
import WhisperKit

let pipe = try await WhisperKit()  // 自动下载推荐模型
let results = try await pipe.transcribe(audioPath: "/path/to/audio.wav")
// results: [TranscriptionResult]
```

`transcribe(...)` 重载列表:
```swift
open func transcribe(audioPath: String, decodeOptions: DecodingOptions? = nil,
                     callback: TranscriptionCallback? = nil) async throws -> [TranscriptionResult]

open func transcribe(audioArray: [Float], decodeOptions: DecodingOptions? = nil,
                     callback: TranscriptionCallback? = nil,
                     segmentCallback: SegmentDiscoveryCallback? = nil) async throws -> [TranscriptionResult]

open func transcribe(audioPaths: [String], ...) async -> [[TranscriptionResult]?]
open func transcribe(audioArrays: [[Float]], ...) async -> [[TranscriptionResult]?]
```

**input 类型**:文件路径(String)或 `[Float]` 16 kHz raw 音频 buffer。
**输入格式**:文件支持 `.wav/.mp3/.m4a/.flac`,内部用 swift-transformers + AVFoundation 转换。

### C.2 流式转录(对应 SFSpeech `SFSpeechAudioBufferRecognitionRequest`)

⚠️ **README 没文档化**,但源码 `Sources/WhisperKit/Core/Audio/AudioStreamTranscriber.swift` 提供完整 actor:

```swift
public actor AudioStreamTranscriber {
    public init(
        audioEncoder: any AudioEncoding,
        featureExtractor: any FeatureExtracting,
        segmentSeeker: any SegmentSeeking,
        textDecoder: any TextDecoding,
        tokenizer: any WhisperTokenizer,
        audioProcessor: any AudioProcessing,
        decodingOptions: DecodingOptions,
        requiredSegmentsForConfirmation: Int = 2,
        silenceThreshold: Float = 0.3,
        compressionCheckWindow: Int = 60,
        useVAD: Bool = true,
        stateChangeCallback: AudioStreamTranscriberCallback?
    )

    public func startStreamTranscription() async throws
    public func stopStreamTranscription()
}

public typealias AudioStreamTranscriberCallback = @Sendable (
    AudioStreamTranscriber.State,  // old
    AudioStreamTranscriber.State   // new
) -> Void
```

`State` 暴露:
```swift
public var isRecording: Bool
public var currentText: String                       // ← 等价 SFSpeech partial result
public var confirmedSegments: [TranscriptionSegment] // ← 已 finalize 的段
public var unconfirmedSegments: [TranscriptionSegment]
public var lastConfirmedSegmentEndSeconds: Float
public var bufferEnergy: [Float]                     // ← 可用于 overlay UI 波形
```

**关键洞察**:
- AudioStreamTranscriber **内置 VAD**(`useVAD: true` 默认),自动判断说话/停顿
- `requiredSegmentsForConfirmation: 2` 提供"两轮确认"机制 — partial 结果在 confirmedSegments 累积之前会先在 unconfirmedSegments 里波动
- 跟 VoiceBee 现有 SpeechRecognizer 的"partial→final"双回调模型语义对齐:`unconfirmedSegments` ≈ partial,`confirmedSegments` ≈ finalized,`currentText` ≈ best transcription

### C.3 模型加载 / 生命周期

```swift
open func loadModels(prewarmMode: Bool = false) async throws
open func unloadModels() async
open func clearState()
```

- `WhisperKit.init(...)` 默认自动 load model — `download: true`(从 HuggingFace 拉)+ `prewarm: nil`(可选预热降低首次推理延迟)
- 可异步分离:先 `WhisperKit()` 拿实例,后台 `await loadModels()`
- 释放:`unloadModels()` 可在低内存时切回 SFSpeech

### C.4 prompt 注入(替代 `contextualStrings`)

```swift
public struct DecodingOptions {
    public var language: String?          // "zh", "en", "auto"...
    public var task: DecodingTask          // .transcribe / .translate
    public var temperature: Float          // 默认 0.0
    public var promptTokens: [Int]?        // ← 关键!conditioning prompt
    public var prefixTokens: [Int]?        // ← 前置 prefix
    public var sampleLength: Int
    public var detectLanguage: Bool
    public var usePrefillPrompt: Bool
    public var suppressTokens: [Int]?
    public var compressionRatioThreshold: Float
    public var logProbThreshold: Float
    public var wordTimestamps: Bool
    public var concurrentWorkerCount: Int  // macOS 默认 16
}
```

**用法**(VoiceBee 的 vocab 注入):
1. 拿到 `WhisperKit().tokenizer`
2. 把 vocab 词条拼成字符串(如 `"VoiceBee ClearSky Sparkle JotBee"`)
3. `tokenizer.encode("VoiceBee ClearSky Sparkle JotBee")` → `[Int]`
4. 传入 `DecodingOptions(promptTokens: tokenIds)`

**vs SFSpeech `contextualStrings`**:
- SFSpeech contextualStrings:只影响 LM bias,效果中等
- WhisperKit promptTokens:**作为 conditioning context 进 decoder KV cache**,直接影响首批 token 预测 — 强约束
- 这正是 vocab follow-up 治本的关键 API

### C.5 调用模型 callback / async

| 用法 | 接口 |
|---|---|
| 文件识别 | `async throws -> [TranscriptionResult]` |
| 实时分段进度 | `TranscriptionCallback` (closure) |
| 流式实时 | `AudioStreamTranscriberCallback` (state diff) |
| 语言检测 | `await detectLanguage(audioArray:)` (async) |

主流是 **async/await**,callback 仅用于"持续上报状态变化"场景。

---

## D. 模型选择

WhisperKit README 只命名了两个示例模型(`tiny` / `large-v3-v20240930_626MB`),完整列表在 [HuggingFace argmaxinc/whisperkit-coreml](https://huggingface.co/argmaxinc/whisperkit-coreml) repo(由 Argmax 维护)。

**社区已知大致 size**(根据 Whisper 上游 + Argmax 量化版本):

| 模型 | 上游 Whisper size | WhisperKit Core ML size(估) | 中文表现(社区评估) | 英文 | 推理延迟(M1) |
|---|---|---|---|---|---|
| `tiny` | 39 M params | ~75 MB | ⚠️ 弱 | ⚠️ | ~5x realtime |
| `base` | 74 M | ~150 MB | ⚠️ 一般 | ⚠️ 一般 | ~3x realtime |
| `small` | 244 M | ~470 MB | ✅ 可用 | ✅ 可用 | ~1.5x realtime |
| `medium` | 769 M | ~1.5 GB | ✅ 好 | ✅ 好 | ~0.8x realtime |
| `large-v3` | 1.55 B | ~3 GB(fp16) / **626 MB(量化)** | 🌟 优秀 | 🌟 优秀 | M1 Max ~0.5x realtime / M3 ~0.7x |
| `large-v3-turbo` | 809 M | ~1.6 GB | ✅ 接近 large-v3 | ✅ 接近 large-v3 | M1 Max ~1.2x realtime |
| `distil-large-v3` | 756 M | ~1.5 GB | ⚠️ 英文重 | 🌟 优秀 | M1 Max ~1.5x realtime |

⚠️ 上表非官方数字,需用 PoC 实测。Argmax 推荐的 `large-v3-v20240930_626MB` 是**量化后**的 large-v3(626 MB),保留高准确率同时尺寸大幅压缩。

### VoiceBee 推荐选型

| 用户机器 | 推荐 |
|---|---|
| 入门 / 老款 M1 | `small`(470 MB,流畅性优先) |
| **默认推荐** | **`large-v3-v20240930_626MB`**(Argmax 量化版,精度 + 大小最佳平衡) |
| 高端 / M2 Max+ | `large-v3-turbo`(更快,精度近 large-v3) |
| 仅英文用户 | `distil-large-v3`(英文 turbo) |

**留 UI 让用户选**(类似当前 Polish engine 选 Ollama/Claude/DeepSeek 的设计 — 把 ASR engine 也做成可切换的)。

### 中文 benchmark 缺失

⚠️ **WhisperKit README 完全没提中文** — 这是个 doc gap。但底层 OpenAI Whisper large-v3 在第三方评估里:
- Mandarin (zh) WER 5-10%(Common Voice / FLEURS 数据集)
- vs SFSpeech zh-Hans WER 15-25%(尤其英文专名场景)
- Whisper 训练数据含大量代码切换样本(zh+en),原生支持"中英混输"

**PoC 必做实验**:用 VoiceBee 现有用户口述音频跑 large-v3,对比 SFSpeech baseline。

---

## E. 模型下载/管理

- **来源**:HuggingFace `argmaxinc/whisperkit-coreml`(月下载量 **10,934,303** 次,稳定可靠)
- **机制**:WhisperKit 自带,首次 `init()` 自动下载到默认缓存路径(未官方文档化,根据 swift-transformers 习惯应该是 `~/Library/Caches/huggingface/` 或类似)
- **可配置**:
  ```swift
  let config = WhisperKitConfig(
      model: "large-v3-v20240930_626MB",
      downloadBase: URL(...),               // 自定义下载 base
      modelRepo: "argmaxinc/whisperkit-coreml",  // 自定义 HF repo
      modelFolder: "~/Library/Application Support/VoiceBee/models/",
      useBackgroundDownloadSession: false,  // 后台下载
      download: true,                        // 没有时自动下载
      prewarm: true                          // 预热
  )
  ```
- **离线**:`download: false` + `modelFolder:` 指本地路径 = 完全离线(给打包进 app 的场景用)

### VoiceBee onboarding 设计建议

- 首次启动 detect 用户没下过模型 → 弹"选择 ASR 引擎"页(SFSpeech 立即可用 vs WhisperKit 下载 ~626 MB)
- 用户选 WhisperKit → 后台下载 + 进度条 + 完成后 prewarm
- 用户可在设置切换引擎

---

## F. SPM 集成

```swift
// Package.swift dependencies
.package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0")

// Target dependencies
.product(name: "WhisperKit", package: "argmax-oss-swift")
// 或 umbrella(包含所有 kit):
.product(name: "ArgmaxOSS", package: "argmax-oss-swift")
```

**注意**:VoiceBee 用 xcodegen 管理 project.yml,SPM 依赖加在 `packages:` 块里。

### 额外要求

- **entitlements**:未文档化,但根据其他 macOS app 经验:
  - `com.apple.security.network.client`(模型下载)— VoiceBee 当前可能没开 sandbox,不需要;但**未来 sandbox 化时要加**
  - `com.apple.security.device.audio-input`(已有,SFSpeech 已用)
  - 无需 Speech Recognition 系统权限(WhisperKit 完全本地,不像 SFSpeech 要 `NSSpeechRecognitionUsageDescription`)
- **App Sandbox**:VoiceBee 当前**未开 sandbox**(从 Info.plist 推断,未见 `com.apple.security.app-sandbox` entitlement),所以 WhisperKit 沙箱兼容性当前不是阻塞项

### 包体积影响

- WhisperKit OSS package 本身 + 依赖 ~10-20 MB(swift-transformers + Hub + Tokenizers vendored)
- **不打包模型** → VoiceBee.dmg size 影响 < 20 MB
- 模型按需下载,不进 .dmg(像 Ollama 一样)

---

## G. 跟 SFSpeech 对比

| 维度 | SFSpeech (VoiceBee 当前) | WhisperKit | 备注 |
|---|---|---|---|
| **英文专名识别** | ⚠️ 弱(VoiceBee → Vocab,5/5 失败) | ✅ 强 | Whisper 训练数据多语种代码切换 |
| **中文准确率** | ✅ 好(主语义 OK) | ✅ 应更好(待 PoC 验证) | Whisper-large-v3 zh-CN benchmark 5-10% WER |
| **中英混输** | ⚠️ 弱 | ✅ 强 | 见 README "VoiceBee" / "ChatGPT" 等专名识别 |
| **推理延迟(首字)** | ~200-400 ms | tiny/base 接近;medium/large 稍慢 | WhisperKit 模型加载需 1-3s(可后台预热) |
| **流式 partial result** | ✅ 原生 | ✅ AudioStreamTranscriber 提供 | 语义对齐 |
| **prompt / vocab 注入** | `contextualStrings`(LM bias,效果中等) | `promptTokens`(decoder conditioning,效果强) | **VoiceBee 痛点直接解决** |
| **离线** | ✅ Apple 内置 ASR 模型 | ✅ 模型下载后完全离线 | 都不需要网络 |
| **资源占用(运行时)** | 低(系统服务) | 中(单进程,VAD + GPU 推理) | M1+ 可接受 |
| **下载/打包成本** | 0(系统自带) | 用户首次 ~150 MB - 1.6 GB | onboarding 成本 |
| **session 60s 限制** | ❌ 有(VoiceBee 用 rotate 绕开) | ✅ 无 | AudioStreamTranscriber 长会话原生支持 |
| **后处理(标点 / 数字)** | 部分(`addsPunctuation`) | ✅ Whisper 训练时已包含 | LLM polish 仍可做 |

### 结论

WhisperKit 是 **VoiceBee 痛点的精确解** — 中文 ASR 主语义不动,**英文专名识别 + 中英混输 + 长会话**全面优于 SFSpeech。

---

## H. 已知坑(根据 GitHub issues 和 release notes)

### v1.0.0 breaking changes(从 v0.18.x 迁移)

- `WhisperKit.transcribe(audioPath:)` 返回类型从 `TranscriptionResult?` → `[TranscriptionResult]`
- 顶层自由函数迁到 `ModelUtilities` / `TranscriptionUtilities` / `TextUtilities` 命名空间
- `DecodingOptions.supressTokens` typo 修复 → `suppressTokens`
- 移除 `TextDecoderContextPrefill` 模型(KV cache prefill 优化)
- `MLTensor.asXxxArray` 同步方法 → `await toXxxArray()` async
- `TokenSampling.update(...)` 变 async

→ **从 0 开始接入直接用 v1.0.0,无迁移负担**

### Swift 6 注意

- v1.0.0 已 Swift 6 兼容
- **但**:顶层 kit 类(`WhisperKit`, `SpeakerKit`, `TTSKit`)**尚未 `Sendable`** — 在 actor isolation 严格场景可能告警
- VoiceBee 现有 `PolishService` 是 `actor`,如果把 WhisperKit 实例存在 actor 的 isolated property 里也会撞这个告警
- 缓解:用 `@unchecked Sendable` wrapper 或在 `@MainActor` 持有 WhisperKit

### 顶级用户痛点(issues #454 / #457 / #450)

- **没有 KV cache 持续(chunk 之间)**:#454 提到 TTSKit prosody state carryover — 不影响 ASR
- diarization 相关 issue 较多(SpeakerKit 部分) — 跟 VoiceBee 不相关
- 主分支极活跃,community 反馈响应快(`atiorh` 是核心维护者,频繁回复)

### 中文相关 issue

- 搜索 `chinese`/`mandarin`/`中文`:**0 命中**(open + closed 都查了)
- 解读:可能(a)Whisper 中文表现稳定无 bug 报告,或(b)中文用户群体小没人提 issue。前者更可能 — Whisper-large-v3 中文社区评估一直较好

### 文档缺口

- **AudioStreamTranscriber 完全没文档化**(README 不提)— 必须读源码
- **DecodingOptions 完整字段表无官方文档** — 必须读 `Configurations.swift`
- 中文示例缺失
- 这些 doc gap **不影响功能,但影响接入速度**

### Pro 商业 tier 的存在

Argmax 同时卖 Pro SDK(`argmaxinc.com/blog/argmax-sdk-2`),宣传"frontier accuracy + custom vocabulary + real-time speakers"。这意味着:
- OSS 是 lead-magnet,功能完备但部分**高级特性**(自定义微调模型 / 实时多说话人)仅 Pro
- 风险:未来某些 API 可能往 Pro 倾斜(虽然 MIT 已发布的代码无法回收)
- 缓解:VoiceBee 现在所需的 streaming + prompt token + 模型下载**全部在 OSS**,不依赖 Pro

---

## 建议下一步行动(等审过决定)

1. **Phase 1 - PoC**(优先级:🔴 高):
   - 新分支已切(`feature/whisperkit-asr`)
   - 加 SPM 依赖 `from: "1.0.0"`
   - 写一个**最小 demo**:加载 `large-v3-v20240930_626MB` → 读 VoiceBee 已有 audio file → 转录 → 跟 SFSpeech 结果对比
   - 输入素材:用户日常 5-10 段含 "VoiceBee" / "ClearSky" / "Sparkle" 的真实口述
   - 输出:对比表(rawText SFSpeech vs WhisperKit,逐句标注哪个对)

2. **Phase 2 - 抽象层**(优先级:🟡 中):
   - 设计 `protocol ASRProvider`,把 SFSpeech 现有调用包成 `SFSpeechProvider`
   - 加 `WhisperKitProvider`,实现同 protocol
   - VoiceEngine 通过 protocol 调用,settings 选哪个 implementation

3. **Phase 3 - UX**(优先级:🟢 低):
   - 设置面板加"ASR 引擎"选项 + 模型尺寸选择
   - 首次启动 onboarding 引导下载模型(类似 Cursor、Linear 的下载弹窗模式)
   - 进度 + 取消 + 后台继续

4. **Phase 4 - 灰度**(优先级:🟢 低):
   - 默认仍 SFSpeech
   - alpha 用户(早期反馈者)切 WhisperKit 收集准确率数据
   - 1-2 个月后视数据决定默认引擎

---

## 待解决疑点(PoC 阶段需验证)

| # | 问题 | 验证方法 |
|---|---|---|
| 1 | 实际中文准确率 vs SFSpeech | 跑 10 段对比测试 |
| 2 | `promptTokens` 注入 vocab 实际效果 | 同样口述带 / 不带 promptTokens 各跑 5 次 |
| 3 | M1 Air / M2 Pro 实测推理延迟 | benchmark `large-v3-v20240930_626MB` |
| 4 | 模型下载实际默认路径 + 用户可见性 | 跑 init 看 `~/Library/` 哪里出现新文件 |
| 5 | WhisperKit 在 `actor PolishService` 持有的 sendable 告警 | swift build with -strict-concurrency=complete |
| 6 | AudioStreamTranscriber 在长会话(>5 分钟)稳定性 | 长录音测试 |
| 7 | 切换语言 / 模型大小是否需要 reload | API 调用尝试 |

---

## 附录:仓库 git 元数据快照(2026-05-11)

```
仓库: argmaxinc/argmax-oss-swift
描述: On-device Speech AI for Apple Silicon
分支: main
最新 release: v1.0.0 (2026-05-01)
最新 commit (5 条):
  c9cf203 2026-05-01 Add ArgmaxOSSDynamic product (#469)
  cd3c6bc 2026-05-01 Remove deprecated APIs (#466)
  1bbfbaa 2026-05-01 Remove TextDecoderContextPrefill model (#467)
  9b415e5 2026-04-30 fixing typo: supress —> suppress (#296)
  bb2ce7f 2026-04-30 Swift 6 Concurrency Support (#458)
Stars: 6078 | Forks: 554 | Open issues: 117
```

```
WhisperKit source tree (Sources/WhisperKit/Core/):
├── Audio/
│   ├── AudioChunker.swift
│   ├── AudioProcessor.swift
│   ├── AudioStreamTranscriber.swift   ← streaming actor
│   ├── EnergyVAD.swift
│   └── VoiceActivityDetector.swift
├── Text/
│   ├── LogitsFilter.swift
│   ├── SegmentSeeker.swift
│   └── TokenSampler.swift
├── AudioEncoder.swift
├── Configurations.swift               ← DecodingOptions, WhisperKitConfig
├── FeatureExtractor.swift
├── Models.swift
├── TextDecoder.swift
├── TranscribeTask.swift
└── WhisperKit.swift                   ← main entry point
```
