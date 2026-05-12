# WhisperKit Streaming Spike — Phase 2B 第一份事实记录

> **Spike 日期**: 2026-05-12
> **分支**: feature/whisperkit-asr
> **目标(回应 `docs/asr-provider-design.md` 实施顺序节顶部声明)**: 验证 WhisperKit 能否做实时流式 ASR — 接收实时音频、产 partial、产 final
> **结果**: ✅ API 存在 + 编译通过 / ⚠️ 集成形态与原 ASRProvider 草案前提**冲突**,需要回到 D1 决策点重新评估

---

## TL;DR

| 维度 | 结果 |
|---|---|
| WhisperKit 1.0.0 流式 API 存在? | ✅ 是 — `AudioStreamTranscriber` actor + `stateChangeCallback` |
| Spike 代码编译? | ✅ 通过(`swift build --target WhisperKitStreamSpike`,16.87s) |
| Runtime 麦克风 → partial / final? | ⏳ **待用户在真实终端跑确认**(Claude Code Bash 无 tty + 无麦克权限) |
| 跟 ASRProvider 草案 (D1 推荐"closure callbacks + 同步 appendBuffer") 一致? | ❌ **冲突** — WhisperKit 是 pull 模型,**它自己持有麦克风**,不接受外部 buffer |
| 需要 fallback (chunk-and-transcribe) 吗? | ⏳ 取决于 runtime 结果 — 如果实测产空输出 → 启用 fallback;recipe 已在本文末附完整代码 |

---

## A. WhisperKit 流式 API 的真相

### A.1 关键源码定位

| 路径(相对 `Tools/WhisperKitPoC/.build/checkouts/argmax-oss-swift/Sources/`) | 角色 |
|---|---|
| `WhisperKit/Core/Audio/AudioStreamTranscriber.swift` | 流式核心 — actor,持有 audioProcessor + decodingOptions + state |
| `WhisperKit/Core/Audio/AudioProcessor.swift` | 麦克风 + 缓冲管理 — 通过 `startRecordingLive` 自起 `AVAudioEngine` |
| `ArgmaxCLI/TranscribeCLI.swift:275-320` | 官方 CLI 流式参考实现(`argmax-cli transcribe --stream`) |

### A.2 真实 API 签名(从源码摘)

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

    public func startStreamTranscription() async throws  // 阻塞 — 内部 realtimeLoop while isRecording
    public func stopStreamTranscription()
}

public typealias AudioStreamTranscriberCallback = @Sendable (
    AudioStreamTranscriber.State,   // old
    AudioStreamTranscriber.State    // new
) -> Void

public extension AudioStreamTranscriber {
    struct State {
        public var isRecording: Bool = false
        public var currentText: String = ""              // 实时 partial (含 "Waiting for speech..." 哨兵)
        public var confirmedSegments: [TranscriptionSegment] = []   // 已确认段
        public var unconfirmedSegments: [TranscriptionSegment] = [] // 尚可被 fallback 改写的段
        public var bufferEnergy: [Float] = []
        public var lastConfirmedSegmentEndSeconds: Float = 0
        // ...
    }
}
```

### A.3 ⚠️ 致命发现:WhisperKit 是 **pull 模型**

`AudioStreamTranscriber.startStreamTranscription()` 内部:

```swift
state.isRecording = true
try audioProcessor.startRecordingLive { [weak self] _ in
    Task { [weak self] in await self?.onAudioBufferCallback() }
}
await realtimeLoop()   // while isRecording { try await transcribeCurrentBuffer() }
```

即 **`audioProcessor`(默认是 WhisperKit 自带的 `AudioProcessor`)自己拿麦克风** — `transcribeCurrentBuffer` 从 `audioProcessor.audioSamples`(`ContiguousArray<Float>`)读累积样本,**不存在让外部 buffer push 进去的公开 API**。

`AudioProcessing` protocol 暴露的写入面只有:
- `startRecordingLive(inputDeviceID:, callback:)` — 拉麦克风
- `startStreamingRecordingLive(...)` — 返回 AsyncStream(也是麦克风产出方向)
- `audioSamples` 是 `{ get }`,protocol 层不暴露 write
- `processBuffer([Float])` 是 `AudioProcessor` class 的 **internal** 方法(line 907),不在 protocol 上

### A.4 这意味着什么(对 ASRProvider 草案)

`docs/asr-provider-design.md` D1 推荐的 protocol 形态:

```swift
nonisolated func appendBuffer(_ buffer: AVAudioPCMBuffer)
```

—— **这跟 WhisperKit 的设计哲学不兼容**。两条出路:

| 选项 | 描述 | 复杂度 | VoiceBee 影响 |
|---|---|---|---|
| **W-A. 让 WhisperKit 接管麦克风** | WhisperKit engine 路径下 VoiceBee 弃用自己的 `AudioRecorder`,把麦克风让给 WhisperKit 的 `AudioProcessor` | 低 | `AudioRecorder.onAudioBuffer` 在此引擎下不接通;hotkey "按住说话" 仍可起停 `AudioStreamTranscriber` |
| **W-B. 实现自定义 `AudioProcessing` conformer** | VoiceBee 继续持有 mic,把 `AudioRecorder` 包成 `AudioProcessing`,内部维护 `audioSamples` + `relativeEnergy` 喂给 `AudioStreamTranscriber` | 中-高 | 需实现 ~5 个 protocol method + relativeEnergy 计算 + VAD 兼容性 |
| **W-C. 完全绕过 `AudioStreamTranscriber`** | VoiceBee 持有 mic,自己攒 buffer 周期性调 `WhisperKit.transcribe(audioArray:)`(chunk-and-transcribe) | 低 | 失去 WhisperKit 内置 VAD + 段确认逻辑,需要自己实现简单 partial 策略 |

→ **本 spike 验的是 W-A**(最直接路径),其他两条是后备。

---

## B. Spike 实现

### B.1 文件位置

| 路径 | 角色 |
|---|---|
| `Tools/WhisperKitPoC/Package.swift` | 添加第二个 `executableTarget: WhisperKitStreamSpike` |
| `Tools/WhisperKitPoC/Sources/WhisperKitStreamSpike/main.swift` | spike 入口 — AudioStreamTranscriber + stateChangeCallback + 延迟探针 |

### B.2 核心结构

- 用 `WhisperKitConfig(model: ..., prewarm: true)` + `pipe.loadModels()` 完整 warm
- 复用 `pipe.audioEncoder` / `pipe.featureExtractor` / `pipe.segmentSeeker` / `pipe.textDecoder` / `pipe.tokenizer` / `pipe.audioProcessor` 构造 `AudioStreamTranscriber` — **完全按 ArgmaxCLI 模式**
- 配 `DecodingOptions(task: .transcribe, language: "zh", temperature: 0.0, detectLanguage: false)`
- callback 内:对比 oldState/newState 字段过滤,只在 currentText / confirmedSegments / unconfirmedSegments 变化时打印
- `LatencyProbe actor` 记录从 stream start 到首个 partial 和首个 confirmed segment 的 wall-clock
- SIGINT (Ctrl+C) 处理器在退出前打印延迟摘要

### B.3 编译验证

```bash
$ cd Tools/WhisperKitPoC
$ swift build --target WhisperKitStreamSpike
...
Build of target: 'WhisperKitStreamSpike' complete! (16.87s)
```

→ **API 存在,Swift 6 类型对齐,零编译告警**。

---

## C. 运行(用户在真实终端跑)

### C.1 为什么不能在 Claude Code Bash 里跑

- Claude Code Bash sandbox 无 tty → SIGINT 处理不可用(无法 Ctrl+C 干净退出)
- Bash 进程没有麦克风权限,`AVAudioEngine.start()` 会失败
- 启动是阻塞流式 loop,Bash 会卡到 timeout 然后被强杀

### C.2 运行步骤(你在 Terminal.app / iTerm2 里跑)

```bash
cd ~/Developer/VoiceBee/Tools/WhisperKitPoC

# Release build(推理快很多,首次 ~33s 编译;增量秒级)
swift run -c release WhisperKitStreamSpike
```

第一次启动会:
1. 命令行打印 `[load] Initializing WhisperKit...`
2. 若模型已下载(PoC 已下) → load + prewarm ~7-10s
3. 系统弹麦克风权限对话框(给 Terminal.app 授权)
4. 打印 `Streaming will request microphone permission on first launch.` 后开始听
5. 你说话,callback 每秒触发若干次,打印 partial / confirmed 段
6. **Ctrl+C** → 触发 SIGINT 处理器,打印延迟摘要后 exit

### C.3 预期输出格式

```
==== WhisperKit Streaming Spike ====
Model: openai_whisper-large-v3-v20240930_626MB
Pattern: AudioStreamTranscriber + WhisperKit-owned AVAudioEngine mic
------------------------------------------------------------
[load] Initializing WhisperKit (lazy, then loadModels)...
[load] Models ready in 8.32s
Streaming will request microphone permission on first launch.
Speak for ~10 seconds, then press Ctrl+C to stop.
------------------------------------------------------------
---
[t+  0.20s]
  current:     Waiting for speech...
---
[t+  2.31s]
  current:     今天
>>> first partial at t+2.31s <<<
---
[t+  3.85s]
  current:     今天 VoiceBee
---
[t+  4.90s]
  unconfirmed: 今天 Voizbee 这个产品
>>> first confirmed segment at t+5.40s <<<
---
[t+  5.40s]
  confirmed:   今天 Voizbee 这个产品
  current:
^C
============================================================
LATENCY SUMMARY
  First partial:           2.31s
  First confirmed segment: 5.40s
```

(实际数字未实测,仅基于 source code `transcribeCurrentBuffer` 每秒至少 100ms sleep + VAD + requiredSegmentsForConfirmation=2 推演)

---

## D. 成功 / 失败判定标准

### D.1 ✅ 成功的样子

- 模型加载后 `Streaming...` 提示出现
- 说话 1-3 秒内 `>>> first partial <<<` 出现
- 继续说 3-6 秒后 `>>> first confirmed segment <<<` 出现
- 段文字内容大致对应说的话(包括上文 PoC 测过的英文专名近似 — VoiceBee → Voizbee 这类)

### D.2 ❌ 失败模式 + 对应推断

| 现象 | 推断 |
|---|---|
| 卡在 `Waiting for speech...` 不前进 | VAD 没检测到声音,可能麦克风没授权,或 audioProcessor 没真正连上音频 |
| `>>> first partial <<<` 出现但 `>>> first confirmed segment <<<` 永不出现 | `requiredSegmentsForConfirmation=2` 但没攒满 2 段;说更长一点(>10s) |
| callback 触发但 `currentText` 永远空 | 跟 PoC 实验 E 的 promptTokens 死胡同同症状 — WhisperKit v1.0.0 流式可能有 bug;走 fallback (W-C / chunk-and-transcribe) |
| `transcribeCurrentBuffer` throw error(无 partial,直接 break) | 看打印的 error.localizedDescription,通常是模型加载问题 / Core ML 资源不足 |
| 应用 crash | 看 stderr;可能是 actor reentrancy / @Sendable 违反,记 trace 给我 |

---

## E. Chunk-and-transcribe Fallback Recipe(待激活)

**触发条件**:用户跑 C 节后报告 D.2 的"callback 触发但 currentText 永远空"或类似 runtime 失败。

**思路**:绕开 `AudioStreamTranscriber` 这一层,用 VoiceBee 现有 `AudioRecorder` 攒 buffer,定时写临时 wav → 调 `pipe.transcribe(audioPath:)`(PoC C 节已验证可行,1.0-1.2s / 2 秒音频)。

### E.1 直接可激活的代码(放进新 target `WhisperKitChunkSpike` 即可)

```swift
import AVFoundation
import Foundation
import WhisperKit

@main
struct WhisperKitChunkSpike {
    static let modelName = "openai_whisper-large-v3-v20240930_626MB"
    static let chunkSeconds: Double = 2.5     // 实测可调 — 2-3s 之间
    static let sampleRate: Double = 16_000

    static func main() async {
        do { try await run() } catch { print("FAILED: \(error)"); exit(1) }
    }

    static func run() async throws {
        let config = WhisperKitConfig(model: modelName, prewarm: true)
        let pipe = try await WhisperKit(config)
        try await pipe.loadModels()
        print("[load] WhisperKit ready")

        // 1. 起 AVAudioEngine 自己拉麦克
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFormat, to: targetFormat)!

        let chunkFrames = AVAudioFrameCount(chunkSeconds * sampleRate)
        var accumulator: [Float] = []
        accumulator.reserveCapacity(Int(chunkFrames) * 2)
        let queue = DispatchQueue(label: "spike.chunker")
        let chunkChannel = AsyncStream<[Float]> { continuation in
            input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
                // resample to 16kHz mono float32
                let outCap = AVAudioFrameCount(
                    Double(buffer.frameLength) * sampleRate / inputFormat.sampleRate) + 16
                let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCap)!
                var err: NSError?
                converter.convert(to: out, error: &err) { _, status in
                    status.pointee = .haveData; return buffer
                }
                guard err == nil, let ptr = out.floatChannelData?[0] else { return }
                let floats = UnsafeBufferPointer(start: ptr, count: Int(out.frameLength))
                queue.async {
                    accumulator.append(contentsOf: floats)
                    while accumulator.count >= Int(chunkFrames) {
                        let chunk = Array(accumulator.prefix(Int(chunkFrames)))
                        accumulator.removeFirst(Int(chunkFrames))
                        continuation.yield(chunk)
                    }
                }
            }
        }

        try engine.start()
        print("Listening — speak then Ctrl+C")

        let options = DecodingOptions(task: .transcribe, language: "zh", temperature: 0.0)
        let start = Date()
        var chunkIndex = 0
        for await chunk in chunkChannel {
            chunkIndex += 1
            let t0 = Date()
            // 关键技巧:`transcribe(audioArray:)` 不需要文件,跳过 wav 写入
            let results = try await pipe.transcribe(audioArray: chunk, decodeOptions: options)
            let infer = Date().timeIntervalSince(t0)
            let text = results.map(\.text).joined(separator: " ")
            print(String(format: "[t+%.2fs chunk %d, infer %.2fs] %@",
                         Date().timeIntervalSince(start), chunkIndex, infer, text))
        }
    }
}
```

### E.2 Fallback 路径的 trade-off

| 维度 | AudioStreamTranscriber (本 spike) | chunk-and-transcribe (E.1) |
|---|---|---|
| 实时性 | 1-2s partial,3-5s confirmed | 2.5s 一段固定(可调) |
| 段边界处理 | 内置 VAD + 段确认(更智能) | 固定窗口,可能切断词 |
| WhisperKit 控制深度 | 用其全部内置策略 | 我们做主,简单可控 |
| 复杂度 | 低(库做了) | 中(自己写 chunker) |
| 跟 ASRProvider 草案 fit | 需 D1 重新设计 | 仍可用 push 模型 |

→ 如果 W-A 路径 runtime 出问题,**chunk-and-transcribe 是已被 PoC 验证可行的安全 fallback**,代码已写好。

---

## F. 对 `docs/asr-provider-design.md` 的影响

### F.1 必须重审 D1

`asr-provider-design.md` 的 D1 推荐 closure-based callbacks + 同步 `appendBuffer` — 这个**前提对 WhisperKit 的 push 假设是错的**。

新选项:

| 方案 | protocol 形态 | SFSpeech fit | WhisperKit fit |
|---|---|---|---|
| **D1-redo-A**: provider 自管 mic | `func startStreaming(...) → onPartial / onFinal callback`,protocol 不含 `appendBuffer`,VoiceEngine 不持 AudioRecorder | SFSpeechProvider 内部起 AVAudioEngine(把 VoiceBee 现 AudioRecorder 移到 provider 内部) | 完美:直接调 `AudioStreamTranscriber.startStreamTranscription()` |
| **D1-redo-B**: 仍 push,但 WhisperKitProvider 写自定义 `AudioProcessing` conformer | 当前 D1 形态保留 | 不变 | 中复杂度:实现 ~5 个 protocol method + relativeEnergy 计算 |
| **D1-redo-C**: 让 protocol "可选" 暴露两种形态 | `protocol ASRProvider` 不要 `appendBuffer`,加 `ownsMicrophone: Bool`;true 时 VoiceEngine 让出 mic,false 时仍 push | 复杂 — 两套调用路径并存 | 复杂 |

**初步倾向**:**D1-redo-A — provider 自管 mic**。理由:
- WhisperKit 设计哲学就是 "我管 mic",对抗它(写 AudioProcessing conformer)是逆设计
- VoiceBee 现 `AudioRecorder` 不复杂,挪进 `SFSpeechProvider` 内部成本可控
- protocol 反而更干净 — provider 自己负责音频生命周期

需要你拍板。这是 D8(新增) 还是 D1 重做,等你决定。

### F.2 实施顺序节顶部的 "spike 不可行 → fallback" 声明仍然有效

`asr-provider-design.md` 的:
> Phase 2B 第一个任务是 spike WhisperKit 流式音频接口(`audioProcessor.processAudioBuffer`),如果流式不可行,退回 chunk-and-transcribe 方案

这条声明在 spike 编译通过 + 等待用户跑通后**保持有效**:fallback recipe 已就绪,但激活前提是 runtime 失败(D.2)。

---

## G. 待办(等用户审 + 用户跑)

| # | 任务 | 谁 | 状态 |
|---|---|---|---|
| 1 | 在 Terminal 里跑 `swift run -c release WhisperKitStreamSpike`,讲 5-10 秒中文混英专名 | 用户 | ⏳ 等 |
| 2 | 报告 D.1 / D.2 哪条命中 + 延迟摘要 | 用户 | ⏳ 等 |
| 3 | 如果命中 D.2 失败模式 → 把 E.1 代码挪进 `Sources/WhisperKitChunkSpike/main.swift` 新 target | Claude | 待触发 |
| 4 | 根据 runtime 结果回到 `docs/asr-provider-design.md` 改 D1 决策(D1-redo-A / B / C) | 我们一起 | 待触发 |

---

## 附录:运行环境快照

```
日期: 2026-05-12
分支: feature/whisperkit-asr
PoC 路径: Tools/WhisperKitPoC/
新增 target: WhisperKitStreamSpike
新增文件: Sources/WhisperKitStreamSpike/main.swift (≈140 行)
swift build --target WhisperKitStreamSpike: ✅ 16.87s
WhisperKit 版本: 1.0.0 (argmaxinc/argmax-oss-swift)
模型: openai_whisper-large-v3-v20240930_626MB (PoC 已下,在 ~/Documents/huggingface/)
```
