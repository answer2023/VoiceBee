# ASRProvider 抽象层设计文档(Phase 2 宪法)

> **Purpose**: 把 VoiceBee 现有 SFSpeech 单一 ASR 实现,抽象成可插拔的 `ASRProvider` protocol,让 SFSpeech 与 WhisperKit 在同一接口下并行,UI 可在 Settings 切换。
>
> **Status**(updated 2026-07-04): ✅ **已拍板并全部落地实现**(Phase 2C–2F,2026-05-12 ~ 05-13)。D1-D7 决策全部按本文实施,落地文件:`VoiceJar/Services/ASRProvider.swift`(protocol + 类型)/ `SFSpeechProvider.swift`(Phase 2C)/ `WhisperKitProvider.swift`(Phase 2D)/ `VoiceEngine.swift`(Phase 2E-a 接入 + 2F 切换);旧 `SpeechRecognizer` / `AudioRecorder` 已删除(Phase 2E-b)。2026-07-04 审计加固:WhisperKitProvider 增加 session-token 过滤旧 session 残余回调(`88aeb9b`),VoiceEngine prepare 陈旧事件按实例身份(ObjectIdentifier)过滤(`3af28ca`)。本文保留原设计推理,与实现的偏差以带日期的注记标出。

---

## Context

PoC 已完成(2026-05-11,见 `docs/whisperkit-poc-results.md`):

- **WhisperKit large-v3 on M1 Max**: 推理 1.0-1.2s / 2 秒音频,冷启首推 7.22s;模型 626 MB,首次下载 + load + prewarm 304s
- **已知英文专名**: 100% 正确(`ClearSky` / `MacOS` / `App`)
- **新造专名**: 听出英文但拼写近似(`VoiceBee` → `Voizbee` / `Boysbee`,`JotBee` → `Jotby`)— 仍**质的飞跃**于 SFSpeech 的完全失声(`VoiceBee` → `Vocab`)
- **`promptTokens` 治根**: 当前死胡同 — 3 种 prompt 文本 + 4 种阈值组合均输出空字符串(WhisperKit v1.0.0 行为未明,Phase 2 留作开放问题)
- **当前 fallback**: 按 D 方案(无 vocab 注入)上线 WhisperKit 已显著优于 SFSpeech;后续靠 post-processor 编辑距离 fuzzy match 修拼写,或 promptTokens 修通后切回

抽象层目标:让 VoiceEngine 不感知 provider 实现细节(包括 SFSpeech 的 60s 限制 / WhisperKit 的模型加载),UI 切换零侵入。

---

## D1 (revised 2026-05-12): provider 自管麦克风(pull 模型)

> **Status**: revised after Phase 2B spike(见 `docs/whisperkit-streaming-spike.md`)。原 D1 假设的 push 形态(VoiceEngine 持 `AudioRecorder` → provider.appendBuffer)与 WhisperKit 设计哲学冲突,**已 superseded**。

### Spike 实测发现(2026-05-12)

| 项 | 结果 |
|---|---|
| WhisperKit `AudioStreamTranscriber` 流式可行? | ✅ 是 — 实测首个 partial 在 **模型 ready 后 ~12s 出现**,识别准确 |
| WhisperKit 是 push 还是 pull? | **pull** — `audioProcessor.startRecordingLive(...)` 内部自起 `AVAudioEngine`,无公开 push API |
| 输出后处理负担 | ⚠️ **需在生产里 strip special tokens**(`<|en|>` / `<|zh|>` / `<|transcribe|>` 等控制符) |

### Decision (revised)

**provider 全权管自己的音频管线;VoiceEngine 退化为协调者**:

- VoiceEngine 不再持有 `AudioRecorder`,不再传 PCM buffer
- 每个 `ASRProvider` 实现负责自己的 mic capture + buffer 管理 + 转录 + special-token 清洗
- VoiceEngine 只调 `start(language:, vocabHint:, onPartial:, onFinal:, onError:)` / `stop()` / `cancel()`,并消费回调
- partial / final / error 仍走 `@MainActor` closure(原 D1 选项 A 的 callback 形态保留),理由不变 — 高频回调比 AsyncStream 轻

### Rationale

- **pull 模型是 WhisperKit 的原生设计** — `AudioStreamTranscriber` 与 `AudioProcessor` 紧耦合(`audioProcessor.audioSamples` 是状态共享面),试图写自定义 `AudioProcessing` conformer 把外部 PCM 灌进去是逆设计,复杂度高且失去内部 VAD + 段确认逻辑
- **SFSpeech 也能自管 mic** — 现有 `AudioRecorder`(VoiceJar/Services/AudioRecorder.swift)逻辑简单,挪到 `SFSpeechProvider` 内部作为私有组件成本可控;VoiceEngine 不再需要"先起 recorder 再起 recognizer"的两步协调
- **protocol 更干净** — 删 `appendBuffer` 后 protocol 不依赖 `AVAudioPCMBuffer` / actor 隔离 hack(原 `nonisolated func appendBuffer` 是为对抗 push hot path 的复杂度,pull 模型下消失)
- **VoiceEngine 简化** — 删 `recorder.onAudioBuffer = { ... }` 桥接、删 `rotationTimer`(本来 D3 就要把它内化到 provider),`startRecording()` 只剩 "调 provider.startStreaming + 显示 overlay"
- **special-token 清洗** 是 provider 责任(每个引擎的输出格式不同),在 provider 内部把 raw 模型输出过完滤器再发 onPartial/onFinal,避免 VoiceEngine 看到控制符

### 代价

- **SFSpeech 路径需要重构** — 当前 `AudioRecorder + SpeechRecognizer.appendBuffer` 拆分必须合并到 `SFSpeechProvider` 内部。改动是一次性的,无回归风险(新 protocol 落地前可保留旧路径并行跑)
- **VoiceEngine cancel 路径** — 原来 `recorder.stopRecording()` + `recognizer.cancel()` 两步,改为 `provider.cancel()` 一步;provider 内部协调

### 未变(原 D1 已对的部分)

- partial/final/error 用 closure 而非 AsyncStream — 理由不变(高频回调 + 现有 VoiceEngine `@MainActor` closure 范式一致)
- 生命周期(`prepare()` / `startStreaming()`)用 async — 给模型下载 / 权限请求留 await 点

> **✅ 已实施**(Phase 2C/2D):按本决策落地,`SFSpeechProvider` 内化 mic(`AVAudioEngine` + tap),`WhisperKitProvider` 走 `AudioStreamTranscriber` pull 模型,VoiceEngine 不持 AudioRecorder。
> **2026-07-04 加固**:快速停-启场景下旧 session 回调污染新 session — 两个 provider 都用 `activeSessionToken`(UUID)在主 actor 落地处过滤旧 session 残余回调(WhisperKitProvider 侧为 `88aeb9b` 补齐);`SFSpeechProvider.stop/cancel` 的 `removeTap` 改为无条件执行,防输入设备变更后 tap 残留导致下次 `installTap` 崩溃(`f65938e`)。

---

## D2: 词汇注入接口(vocabulary hint)

### Options

| 选项 | API | SFSpeech 实现 | WhisperKit 实现 |
|---|---|---|---|
| **A. `[String]` 直传** | `startStreaming(vocabHint: [String], ...)` | 直接喂 `contextualStrings` | provider 内部 tokenize → promptTokens **或** post-processor fuzzy match |
| **B. 结构化 hint** | `startStreaming(vocab: VocabHint, ...)` 内含 `terms: [String]` + `aliases: [String: [String]]` 等 | 同上 | provider 可用 aliases 喂 prompt + 后处理替换 |
| **C. 不在 protocol 暴露** | provider 初始化时拿到 `VocabularyManager`,protocol 不知道 | provider 内部读 vocab | 同 |

### Decision(✅ 已实施)

**A. `[String]` 直接传入 `startStreaming`**。

> **实施偏差**(2026-07-04 注):protocol 形态按 A 落地;SFSpeech 侧照喂 `contextualStrings`。但 WhisperKitProvider 内部目前**不消费** `vocabHint`(`_ = vocabHint`,promptTokens 仍是 v1.0.0 死胡同)— 拼写矫正没有做在 provider 内部,而是上移到 **VoiceEngine 层**统一走 `VocabPostprocessor`(Phase 3-A,alias 精确 + Levenshtein fuzzy,`a0d7ff9`;final 段 + stop 快照均矫正,注入/润色/历史路径补齐见 `cbe63ad`),两个引擎共享同一矫正管线。

### Rationale

- vocab 是录音 session 级状态(用户改完词典立即下次录音生效),传入 start 比 provider 内部持有更显式
- `[String]` 是最 portable 形式 — SFSpeech 直接喂 `contextualStrings`,WhisperKit 内部既能 tokenize 成 `promptTokens` 也能交给 post-processor 做 fuzzy match,protocol 不预判
- 现有 `VoiceEngine.swift:293` 已经传 `appState.vocab.activeTerms`(`[String]`),改动最小
- Phase 2 PoC 已确认 vocab 字符串**原文**需要保留(post-processor 编辑距离 fuzzy match 的目标),所以 protocol 用 `[String]` 而不是预编码的 `[Int]`

> **D1 revised 兼容性**: vocab hint 在 `startStreaming(...)` 入参里,跟 push/pull 形态无关,**无需改动**。

---

## D3: SFSpeech 60s rotation(隐藏 vs 暴露)

### Options

| 选项 | rotation timer 归属 | protocol API |
|---|---|---|
| **A. 隐藏在 provider 内部** | SFSpeechProvider 自己起 timer,自动 rotate | protocol 不暴露 rotate |
| **B. 暴露 `func rotate()`** | VoiceEngine 持 timer,显式调 provider.rotate() | protocol 加 `func rotate()`(WhisperKit 空实现) |

### Decision(✅ 已实施)

**A. 隐藏在 provider 内部**。

> **实施注**(2026-07-04):完全按此落地 — `SFSpeechProvider` 内部 `rotationTimer`(55s)+ `internalRotate()`,rotation 旧 session 残余回调用 `activeSessionToken` 过滤;protocol 无 `rotate()`,VoiceEngine 的旧 55s Timer 已随 Phase 2E-b 删除。

### Rationale

- 60s 是 SFSpeech 的**实现细节**(Apple framework 单 session 上限),WhisperKit 无此限制 — VoiceEngine 不该知道
- 当前 `VoiceEngine.swift:331-337` 起 55s `Timer.scheduledTimer` 调 `recognizer.rotate()` 是 leakage,抽象后该消失
- 代价:`SFSpeechProvider` 内部增加 timer 状态;但封装泄漏更糟(WhisperKitProvider 需要空实现 `rotate()` 这种 protocol noise)

> **D1 revised 兼容性**: pull 模型下 SFSpeechProvider 已自管 mic + ASR session,rotation timer 仍藏在 provider 内部,**无需改动**。

---

## D4: 模型管理(protocol 方法 vs 独立 ModelManager)

### Options

| 选项 | 模型生命周期归属 | UI 调用面 |
|---|---|---|
| **A. protocol 方法 polymorphic** | `func prepare() async throws` + `var modelStatus: ASRModelStatus` | UI 拿当前 provider 调 prepare(),不强转 |
| **B. 独立 ModelManager class** | `ModelManager.shared.download(.whisperKit)` | UI 直接调 ModelManager,跨 provider |
| **C. 不抽象** | WhisperKitProvider 内部下载,SFSpeechProvider 空操作,UI 直接判 `if provider is WhisperKitProvider` | 强转地狱 |

### Decision(✅ 已实施)

**A. protocol 内部 polymorphic — `prepare()` + `modelStatus`**。

> **实施偏差**(2026-07-04 注):
> - WhisperKitProvider 未引入独立 `ModelDownloader` 组件 — 下载直接委托 WhisperKit 内部 HF Hub 逻辑。`prepare()` 是**双模式**(2026-05-13 fix):本地模型完整(含手动复制)→ `modelFolder` fast path 直接 load;缺失/不完整 → `downloadBase` 触发自动下载。
> - WhisperKit 内部下载**无公开 progress hook**(W9),`ASRPrepareEvent.downloadProgress` 实际不 fire,只发 `downloadStarted` + `loading` + `ready`。
> - `progress` closure 落地为 `@Sendable`(provider 内部跨 actor 触发),不是草案说的"在主 actor 调用" — VoiceEngine 收到后自行 hop 回 main。

### Rationale

- UI(Settings + Onboarding)不该 `if let wk = provider as? WhisperKitProvider` 强转拿下载接口
- SFSpeechProvider 的 `prepare()` 只做权限请求(秒级),`modelStatus` 直接 `.notRequired` → polymorphic 形态零成本
- WhisperKitProvider 的 `prepare()` 包下载 + load + prewarm,内部组合 `ModelDownloader` 作为 implementation detail
- ModelManager 作为 provider **内部组件**(WhisperKitProvider 持有),不是 cross-provider 跨级实体 — 避免双向依赖

> **D1 revised 兼容性**: 模型管理是 provider 内部生命周期,跟 push/pull 形态无关,**无需改动**。

---

## D5: 错误模型(统一 enum vs Swift typed throws)

### Options

| 选项 | 错误形态 | VoiceEngine 上层 handle 形态 |
|---|---|---|
| **A. 统一 `ASRError` enum** | `enum ASRError { case unavailable / unauthorized / modelMissing / noSpeechDetected / underlying(Error) }` | `switch error { case .noSpeechDetected: ignore; case .unauthorized: alert; ... }` |
| **B. Swift 6 typed throws** | `throws(SFSpeechError)` / `throws(WhisperKitError)` | per-provider switch,无法 share 处理逻辑 |
| **C. NSError 透传** | 现状 | `(error as NSError).code != 1110`(脏代码) |

### Decision(✅ 已实施)

**A. 统一 `ASRError` enum**。

> **实施注**(2026-07-04):按草案落地(6 个 case 一致),`(error as NSError).code != 1110` 脏代码已被 `VoiceEngine.handleASRError` 的 `case .noSpeechDetected` 取代;实现额外给 `ASRError` 加了 `Equatable` conformance(`ASRModelStatus: Equatable` 内嵌 error + 测试比较需要)。

### Rationale

- 消除 `VoiceEngine.swift:312` 的 `(error as NSError).code != 1110` 脏代码 → `case .noSpeechDetected: return`(语义化)
- typed throws 在 Swift 6 仍在 evolving + protocol with associated types 在 typed throws 下复杂度爆炸,不值
- `case .underlying(Error)` 兜底任何 provider-specific 错误(WhisperKit 的 CoreML 错 / SFSpeech 的网络错),UI 用 `error.localizedDescription` 即可
- `noSpeechDetected` 作为 first-class case 让 SFSpeech code 1110 + WhisperKit `noSpeechThreshold` 触发都走同一个忽略路径

> **D1 revised 兼容性**: 错误 enum 跟 push/pull 形态无关,**无需改动**。

---

## D6: 引擎切换 cleanup(用户在 Settings 切 ASR engine)

### Options

| 选项 | 行为 | UX |
|---|---|---|
| **A. 立即 cancel** | 切换瞬间丢当前正在处理的 buffer / utterance | 录音中切引擎 → 当前文本丢失 |
| **B. drain** | 等当前 utterance finalize 再切 | 用户切了但 5s 后才生效,期间状态模糊 |
| **C. 拒绝切换 if 录音中** | Settings UI disable 切换按钮 if `appState.isRecording`,toast 提示 | 简单 clear,corner case 无歧义 |

### Decision(✅ 已实施)

**C. 拒绝切换 if 录音中**。

> **实施注**(2026-07-04):Phase 2F 落地。Picker disable 条件实际为 `.disabled(appState.isRecording || appState.isProcessing || appState.isTranslating)`(比草案多 `isTranslating`);`VoiceEngine.swapProvider` 再做同条件 guard(F7 defense-in-depth)。切换 = `prepareTask.cancel()` + 旧 provider `cancel()` → 新 provider 创建 + 后台 `prepare()`(F8)。实现额外新增两点草案未涉及的行为:1) 切到 whisperKit 前 Settings 弹确认(模型下载体积提示);2) **F6**:新引擎 prepare 失败自动回退 `asrEngine = .sfSpeech` 并提示用户。

### Rationale

- 录音中切引擎是真正的 corner case(用户不会一手按 Fn 一手开 Settings)
- drain 复杂度高 + 用户期望模糊("我点了切换但还在用旧引擎?")
- 切换 = 旧 provider 完整 `cancel()` → release → 新 provider lazy init + 后台 `prepare()`
- Settings UI 实现:`Picker(...).disabled(appState.isRecording || appState.isProcessing)` + 状态文本 "请先停止录音再切换"

> **D1 revised 兼容性**: pull 模型下 provider 自管 mic — `cancel()` 一并停麦克风,VoiceEngine 不需要再单独 stop AudioRecorder。切换策略**无需改动**,实施更简洁。

---

## D7: provider 实例化时机

### Options

| 选项 | 时机 | 首次录音延迟 |
|---|---|---|
| **A. app launch 预创建 + 后台 prepare()** | AppState init 后 Task 起 prepare() | 启动期间多 7-10s(WhisperKit warm)/ 304s(WhisperKit 首次冷启)— 用户看不见,后台跑 |
| **B. lazy init — 第一次 startRecording 时** | 用户按 Fn 触发 init + prepare | **WhisperKit 用户按 Fn 等 7s 才录音 — 不可接受** |
| **C. on-switch 创建** | Settings 切换瞬间 init 新 provider | 切完仍要等 7s warm |

### Decision(✅ 已实施)

**A. app launch 预创建 + 后台 `prepare()` async task**。

> **实施注**(2026-07-04):`VoiceEngine.init` 按 `appState.asrEngine` 创建 provider 后即 `schedulePrepare`(F3)。偏差:prepare 前加 **100ms 启动延迟保险** — 给 `VoiceJarDelegate.requestPermissions` 的 TCC callback 落地窗口,消除两个 TCC 请求同帧 race(Phase 2E-a Thread 3 教训)。
> **2026-07-04 加固**(`3af28ca`):prepare 进度/失败事件按**实例身份**(`ObjectIdentifier(provider)`)过滤 — 同引擎快速来回切换时新旧实例 engine ID 相同,只有实例身份能挡住旧实例的陈旧事件冒充;prepare 失败回滚 sfSpeech(F6)同样受此 guard 保护。

### Rationale

- 用户按 Fn 录音是 hot UX path,**任何可感知延迟都伤体验**
- 启动后台 task 跑 `prepare()` + menubar icon / statusMessage 反馈 "正在准备 WhisperKit..."(类似 Whisper.cpp 应用做法)
- 首次启动 304s 长 — 配合 Onboarding 引导下载 + 进度条(不阻塞录音功能,SFSpeech 同时可用)
- 切换引擎(D6 已规定录音中拒绝)走 destroy-old + prepare-new 流程,UI 显示 "正在切换..."
- 代价:每次 launch 多 7-10s 后台启动开销 + 后台 menory(模型 ~1.2 GB resident)— 接受,VoiceBee 是长驻菜单栏 app

> **D1 revised 兼容性**: prepare() 仍是 provider 的 async 生命周期方法,pull 模型下额外多一步 — 第一次 `startStreaming` 时同步起 AVAudioEngine(几十 ms),不影响 prewarm 时机决策。**无需改动**。

---

## ASRProvider Protocol 草案 (revised 2026-05-12)

> **revised**: 删 `appendBuffer` — provider 自管麦克风(D1 revised),VoiceEngine 退化为协调者。
>
> **✅ 已落地**(2026-07-04 注):正式版在 `VoiceJar/Services/ASRProvider.swift`(Phase 2C),形态与下方草案一致,差异仅在并发标注:`static var id` 标 `nonisolated`;`prepare(progress:)` 的 closure 标 `@Sendable`;`ASREngine` 加 `Sendable`,`ASRPrepareEvent` 加 `Sendable`,`ASRError` 加 `Equatable`。以下代码保留为历史草案,**以 .swift 文件为准**。

```swift
import Foundation
// 注:protocol 层不再需要 AVFoundation — buffer 类型不再跨 provider 边界.
// SFSpeechProvider / WhisperKitProvider 内部各自 import.

// MARK: - Engine identity

enum ASREngine: String, Codable, CaseIterable {
    case sfSpeech
    case whisperKit
}

// MARK: - Model status (D4)

enum ASRModelStatus: Equatable {
    case notRequired                          // SFSpeech
    case missing                              // WhisperKit, 模型未下载
    case downloading(progress: Double)        // 0.0...1.0
    case loading                              // 已下载, Core ML 加载中
    case ready
    case failed(ASRError)
}

enum ASRPrepareEvent {
    case downloadStarted(sizeBytes: Int64)
    case downloadProgress(fraction: Double)
    case loading
    case ready
}

// MARK: - Unified error (D5)

enum ASRError: LocalizedError {
    case unavailable           // recognizer.isAvailable == false / WhisperKit init 失败
    case unauthorized          // SFSpeech 用户拒授权 / 麦克风未授权
    case modelMissing          // WhisperKit 模型未下载
    case modelLoadFailed(Error)
    case noSpeechDetected      // 过滤 SFSpeech code 1110 / WhisperKit silence
    case underlying(Error)     // 兜底

    var errorDescription: String? {
        switch self {
        case .unavailable:        "语音识别服务不可用"
        case .unauthorized:       "缺少语音识别或麦克风权限,请在系统设置中授权"
        case .modelMissing:       "WhisperKit 模型未下载,请前往设置下载"
        case .modelLoadFailed(let e): "模型加载失败: \(e.localizedDescription)"
        case .noSpeechDetected:   nil  // 上层应忽略,不显示
        case .underlying(let e):  e.localizedDescription
        }
    }
}

// MARK: - Protocol

/// 流式 ASR 抽象.所有 closure 回调在主 RunLoop 触发,跟现有 `@MainActor` VoiceEngine 兼容.
/// provider 实现可在内部跳线程,但回调前必须 hop 回 main.
///
/// **D1 revised 责任划分**:
/// - provider 全权管自己的音频管线(麦克风捕获 + buffer 累积 + 转录 + special-token 清洗)
/// - VoiceEngine 是协调者 — 调 prepare / startStreaming / stop / cancel,消费回调
/// - VoiceEngine **不再持有 AudioRecorder**,不再传 PCM buffer 给 provider
@MainActor
protocol ASRProvider: AnyObject {

    // MARK: Identity
    static var id: ASREngine { get }
    var displayName: String { get }

    // MARK: Model lifecycle (D4 + D7)

    /// 当前模型就绪状态.UI 用此显示状态条 / 禁用录音按钮.
    var modelStatus: ASRModelStatus { get }

    /// 预热(权限请求 / 模型下载 / Core ML load / prewarm).
    /// app launch 后 Task 调用 — SFSpeech 秒级返回,WhisperKit 7-300s.
    /// progress 在主 actor 调用,UI 直接 bind.
    func prepare(progress: @escaping (ASRPrepareEvent) -> Void) async throws

    // MARK: Streaming (D1 revised + D2 + D3)

    /// 开启流式 session.provider 内部起麦克风,开始转录.调用前必须 modelStatus == .ready.
    /// - vocabHint: 词典专名,provider 自行决定注入方式(D2)
    /// - onPartial/onFinal 收到的字符串**已清洗 special tokens**(provider 责任,见 spike doc)
    /// - 60s rotation 等实现细节由 provider 内部处理(D3),caller 不感知
    func startStreaming(
        language: String,
        vocabHint: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (ASRError) -> Void
    ) async throws

    /// 停止流式 session,等最终 segment.调用后 onFinal 可能再 fire 1 次.
    /// 跟 cancel 的区别:stop 是用户主动结束录音(松开 hotkey),期待最终结果;
    /// cancel 是 Esc 取消,丢弃 in-flight.
    func stopStreaming() async

    /// 立即取消(Esc).停麦克风,清 callback,丢弃 in-flight 状态.
    func cancel()

    /// 当前累计完整文本(已 finalize 段 + 当前 best),供 stopRecordingAndProcess 拿快照.
    /// special tokens 已清洗.
    var fullTranscript: String { get }
}
```

---

## SFSpeech Fit(伪代码,D1 revised — provider 自管 mic)

> **✅ 已实现**(2026-07-04 注):正式版 `VoiceJar/Services/SFSpeechProvider.swift`(Phase 2C)。与伪代码的关键偏差:
> - installTap closure **不再经 `self` 访问 request** — 改用独立 `@unchecked Sendable` 的 `StreamingRequestBox` 桥接(2026-05-13 Thread 7 crash 教训:`nonisolated(unsafe) var` 在 audio thread 上仍撞 `_dispatch_assert_queue_fail`)
> - `prepare()` 失败时会置 `modelStatus = .failed(.unauthorized)`(伪代码只 throw)
> - `stop/cancel` 的 `removeTap` 无条件执行(2026-07-04 `f65938e`,防设备变更后 tap 残留)
> 以下伪代码保留为设计参考,**以 .swift 文件为准**。

```swift
@MainActor
final class SFSpeechProvider: ASRProvider {
    static let id: ASREngine = .sfSpeech
    var displayName: String { "macOS Speech(内置)" }

    private(set) var modelStatus: ASRModelStatus = .notRequired

    // ⚠️ provider 现在自己持有麦克风(D1 revised)— 把 VoiceBee 现 AudioRecorder
    // 的逻辑挪进来作为私有组件,VoiceEngine 不再持 AudioRecorder.
    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var streamingRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSessionToken: UUID?

    // D3: rotation 隐藏在 provider 内部
    private var rotationTimer: Timer?
    private let rotationInterval: TimeInterval = 55

    private var finalizedSegments: [String] = []
    private var currentBestText: String = ""
    private var contextualStringsCache: [String] = []
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((ASRError) -> Void)?

    func prepare(progress: @escaping (ASRPrepareEvent) -> Void) async throws {
        let auth = await SFSpeechRecognizer.requestAuthorization()
        guard auth == .authorized else { throw ASRError.unauthorized }
        // 注:macOS AVAudioEngine 不需要 requestRecordPermission;mic 权限在首次
        // engine.start() 时由系统弹窗触发.
        progress(.ready)
    }

    func startStreaming(language: String, vocabHint: [String],
                        onPartial: @escaping (String) -> Void,
                        onFinal: @escaping (String) -> Void,
                        onError: @escaping (ASRError) -> Void) async throws {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        contextualStringsCache = vocabHint
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError
        finalizedSegments = []
        currentBestText = ""

        // 1. 起 ASR session
        startSession()
        // D3: 自动起 rotation timer,不暴露
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.internalRotate() }
        }

        // 2. 起麦克风(原 AudioRecorder 内化)— buffer 直接灌到当前 streamingRequest
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // SFSpeechAudioBufferRecognitionRequest.append 是线程安全
            self?.streamingRequest?.append(buffer)
        }
        do {
            try audioEngine.start()
        } catch {
            onError(.underlying(error))
            throw ASRError.underlying(error)
        }
    }

    private func startSession() { /* ... 现有 SpeechRecognizer.swift:77-109 逻辑搬入,error 路径过 noSpeechDetected 转换 ... */ }
    private func internalRotate() { /* ... 现有 rotate() 逻辑 ... */ }

    func stopStreaming() async {
        // 用户松开 hotkey — 停麦克 + 让 ASR finalize 最后一段
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        rotationTimer?.invalidate(); rotationTimer = nil
        streamingRequest?.endAudio()
        // 不清 callback;等 SFSpeech 最后一次 isFinal=true 回来再 fire onFinal
    }

    func cancel() {
        activeSessionToken = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        rotationTimer?.invalidate(); rotationTimer = nil
        recognitionTask?.cancel(); recognitionTask = nil
        streamingRequest?.endAudio(); streamingRequest = nil
        finalizedSegments = []; currentBestText = ""
        onPartial = nil; onFinal = nil; onError = nil
    }

    var fullTranscript: String {
        let parts = finalizedSegments + (currentBestText.isEmpty ? [] : [currentBestText])
        return parts.joined(separator: " ")
    }
}
```

---

## WhisperKit Fit(伪代码,D1 revised — pull 模型原生 fit)

> **✅ 已实现**(2026-07-04 注):正式版 `VoiceJar/Services/WhisperKitProvider.swift`(Phase 2D)。与伪代码的关键偏差:
> - **`VocabPostprocessor.apply` 不在 provider 内** — vocab 矫正上移到 VoiceEngine 层(见 D2 实施偏差注),provider 内 `vocabHint` 暂不消费
> - `prepare()` 是双模式(modelFolder fast path / downloadBase 下载,见 D4 实施偏差注),并先用 `isModelComplete()` 检测三个 mlmodelc 是否就位
> - `stopStreaming()` 增加 **W5**:短录音(<12s)永远等不到 confirmed segment,stop 时强制把 `fullTranscript` 提升为 final fire 一次
> - **2026-07-04 加固**(`88aeb9b`):`activeSessionToken`(UUID)过滤旧 session 残余回调 — transcribe loop 在 `stopStreamTranscription` 后异步退出,快速停-启时旧 transcriber 的 stateChangeCallback / error 落到主 actor 即被 token 比对丢弃;`stopStreaming` 挂起期间 token 轮换也不再污染新 session
> - `fullTranscript` = `confirmedAccum + liveTail`(伪代码只有 confirmed 累加)
> 以下伪代码保留为设计参考,**以 .swift 文件为准**。

```swift
import WhisperKit

@MainActor
final class WhisperKitProvider: ASRProvider {
    static let id: ASREngine = .whisperKit
    var displayName: String { "WhisperKit large-v3" }

    private(set) var modelStatus: ASRModelStatus = .missing

    private var pipe: WhisperKit?
    private var streamer: AudioStreamTranscriber?
    private var streamTask: Task<Void, Error>?

    private var vocabHintCache: [String] = []          // 原文保留,给 post-processor
    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((ASRError) -> Void)?

    private var confirmedTextAccum: String = ""        // 已确认段累加, fullTranscript 源

    private static let modelName = "openai_whisper-large-v3-v20240930_626MB"
    private static var modelFolder: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent("VoiceBee/models")
    }

    func prepare(progress: @escaping (ASRPrepareEvent) -> Void) async throws {
        modelStatus = .loading
        progress(.downloadStarted(sizeBytes: 626_000_000))
        let config = WhisperKitConfig(
            model: Self.modelName,
            modelFolder: Self.modelFolder.path,       // ⚠️ 关键:不污染 ~/Documents
            verbose: false,
            logLevel: .info,
            prewarm: true
        )
        do {
            pipe = try await WhisperKit(config)
            progress(.loading)
            try await pipe!.loadModels()              // ⚠️ lazy init,必须显式调
            modelStatus = .ready
            progress(.ready)
        } catch {
            let asrError = ASRError.modelLoadFailed(error)
            modelStatus = .failed(asrError)
            throw asrError
        }
    }

    func startStreaming(language: String, vocabHint: [String],
                        onPartial: @escaping (String) -> Void,
                        onFinal: @escaping (String) -> Void,
                        onError: @escaping (ASRError) -> Void) async throws {
        guard let pipe, let tokenizer = pipe.tokenizer, modelStatus == .ready else {
            onError(.modelMissing); throw ASRError.modelMissing
        }
        vocabHintCache = vocabHint
        confirmedTextAccum = ""
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError

        let options = DecodingOptions(
            task: .transcribe,
            language: language.hasPrefix("zh") ? "zh" : "en",
            temperature: 0.0,
            detectLanguage: false
            // promptTokens 暂留空 — Phase 2 PoC E 节验证为 v1.0.0 死胡同,
            // 后续靠 post-processor fuzzy match 修拼写
        )

        // ⚠️ D1 revised 关键:WhisperKit AudioStreamTranscriber 内部自起 AVAudioEngine,
        // 我们不需要(也不能)从外部 push buffer. 这是 pull 模型的原生 fit.
        // pipe.audioProcessor 是 WhisperKit 自己的 AudioProcessor 实例.
        streamer = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: options,
            stateChangeCallback: { [weak self] oldState, newState in
                // callback 在 actor 内部触发, @Sendable closure, 需 hop 主 actor
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // ⚠️ Spike 实测发现: raw 输出含 special tokens (<|en|> / <|zh|> /
                    // <|transcribe|> 等控制符), 必须 strip 后再发回 caller.
                    let confirmed = newState.confirmedSegments.map { Self.cleanText($0.text) }.joined(separator: " ")
                    let unconfirmed = newState.unconfirmedSegments.map { Self.cleanText($0.text) }.joined(separator: " ")
                    let live = Self.cleanText(newState.currentText)

                    // 已确认段写入累加, 触发 onFinal (每次新段)
                    if !confirmed.isEmpty, confirmed != self.confirmedTextAccum {
                        self.confirmedTextAccum = confirmed
                        let processed = VocabPostprocessor.apply(confirmed, vocab: self.vocabHintCache)
                        self.onFinal?(processed)
                    }

                    // 未确认 + currentText 走 partial
                    let partial = [confirmed, unconfirmed, live].filter { !$0.isEmpty }.joined(separator: " ")
                    if !partial.isEmpty, partial != "Waiting for speech..." {
                        self.onPartial?(partial)
                    }
                }
            }
        )

        // startStreamTranscription 阻塞 — 包到 Task, 错误回 onError
        streamTask = Task { [weak self] in
            do {
                try await self?.streamer?.startStreamTranscription()
            } catch {
                await MainActor.run { self?.onError?(.underlying(error)) }
                throw error
            }
        }
    }

    func stopStreaming() async {
        // 用户松开 hotkey — 告知 transcriber 停, 但让最后一段 finalize
        await streamer?.stopStreamTranscription()
        // 不取消 streamTask, 让回调 drain 完最后一帧
    }

    func cancel() {
        Task { await streamer?.stopStreamTranscription() }
        streamTask?.cancel()
        streamTask = nil
        streamer = nil
        confirmedTextAccum = ""
        onPartial = nil; onFinal = nil; onError = nil
    }

    var fullTranscript: String { confirmedTextAccum }

    /// 清洗 WhisperKit 输出里的 special token 控制符 (spike 实测发现).
    /// 例: "<|zh|><|transcribe|><|0.00|>今天 VoiceBee<|2.50|>" → "今天 VoiceBee"
    private static func cleanText(_ raw: String) -> String {
        // 匹配 <|...|> 形式的控制符全部移除. 实现阶段用 NSRegularExpression 或现成 lib.
        return raw.replacingOccurrences(
            of: #"<\|[^|]+\|>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

---

## 实施顺序(✅ 已完成 — 原"待 D1-D7 拍板后")

> **Phase 2B 第一个任务是 spike WhisperKit 流式音频接口(`audioProcessor.processAudioBuffer`),如果流式不可行,退回 chunk-and-transcribe 方案(攒 2-3s 音频片段调 `transcribe(audioPath:)`),该方案已在 PoC 验证可行。** 此 spike 决定 `WhisperKitProvider.appendBuffer` 的实现路径,不能阻塞协议落地 — protocol 形态对两种实现都兼容(streaming 直接 forward,chunk-and-transcribe 由 provider 内部攒 buffer + 定时 flush)。
>
> **(2026-07-04 注:此段是 D1 revised 之前的旧前提 — spike 已完成且流式可行,`appendBuffer` 已从 protocol 删除,未走 chunk-and-transcribe 退路。)**

1. ✅ 落 `ASREngine` / `ASRError` / `ASRModelStatus` / `ASRPrepareEvent` 类型(纯数据,无副作用)— Phase 2C `bad2f1f`
2. ✅ 落 `ASRProvider` protocol 定义 — Phase 2C `bad2f1f`
3. ✅ 把现有 `SpeechRecognizer.swift` 重构为 `SFSpeechProvider: ASRProvider`,自测保持现有行为 — Phase 2C(旧文件随 Phase 2E-b `d1b36b1` 删除)
4. ✅ VoiceEngine 改用 `ASRProvider` 接口(暂时硬连 `SFSpeechProvider()`)— 这一步 master 行为不变 — Phase 2E-a `1f5cf6e`
5. ✅ 主 app SPM 加 WhisperKit(`docs/whisperkit-poc-results.md` A 节有步骤)— Phase 2D `daa27a8`
6. ✅ 落 `WhisperKitProvider: ASRProvider`,先 mock vocabHint(不注入,等 promptTokens 研究)— Phase 2D `daa27a8`
7. ✅ Settings UI 加 ASR engine picker + Onboarding 模型下载 — Phase 2F `47251b1`
8. alpha 双轨测试(状态未在 repo 内记录)

---

## 待持续研究的开放问题

- **WhisperKit promptTokens 用法** — Phase 2 留作 spike,5 条具体方向见 `docs/whisperkit-poc-results.md` E 节 **(2026-07-04 注:仍未修通,provider 内 `vocabHint` 暂不消费;过渡方案 VocabPostprocessor 已上线,见下条)**
- **VocabPostprocessor 算法选型** — 编辑距离 / Aho-Corasick / 拼音模糊匹配,留待 promptTokens 修通前的过渡方案 **(✅ 2026-05-16 已定并落地:alias 精确匹配 + Levenshtein fuzzy,Phase 3-A `a0d7ff9`,矫正做在 VoiceEngine 层,双引擎共享)**
- **AudioStreamTranscriber 实际 API surface** — ✅ Phase 2B spike 已实测,源码定位 + 签名 + ArgmaxCLI 参考模式见 `docs/whisperkit-streaming-spike.md`
- **special-token 清洗实现** — Spike 实测发现 WhisperKit 输出含 `<|en|>` / `<|zh|>` / `<|transcribe|>` 等控制符,WhisperKitProvider 用 regex `<\|[^|]+\|>` 移除是临时方案,实施阶段需对照 WhisperKit 内部 tokenizer 行为确认是否漏边界 **(2026-07-04 注:正式版 `WhisperKitProvider.cleanText` 仍用此 regex(W7),"是否漏边界"未做系统性验证,保持开放)**
- **首次 partial ~12s** (Spike 实测) — 比 SFSpeech 慢明显,可能受 large-v3 模型 + VAD `requiredSegmentsForConfirmation=2` 影响,实施阶段需试 `large-v3-turbo` / 调 `silenceThreshold` / 调 `requiredSegmentsForConfirmation` 平衡延迟与稳定性 **(2026-07-04 注:模型仍为 large-v3 626MB,turbo / VAD 参数未试,保持开放;实现侧缓解了衍生问题 — `stopStreaming` 强制把 fullTranscript 提升为 final(W5),短录音不再因等不到 confirmed segment 丢文本)**
- **VoiceEngine 改造范围** — D1 revised 后 VoiceEngine 不再持 AudioRecorder,但仍需保留:overlay 显示 / polish 调度 / 翻译分流;改造时确认现有 `recorder.onAudioBuffer` 和 `rotationTimer` 干净移除,不留死代码 **(✅ 2026-05-13 完成:Phase 2E-b `d1b36b1` 删除 `SpeechRecognizer.swift` + `AudioRecorder.swift`,VoiceEngine 无 recorder / rotationTimer 残留;overlay / polish / 翻译分流保留)**
