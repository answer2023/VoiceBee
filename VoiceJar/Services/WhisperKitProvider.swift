import Foundation
// @preconcurrency:WhisperKit 1.0.0 的 protocol existential(any AudioEncoding 等)
// 未标 Sendable,但 actor `AudioStreamTranscriber.init` 接受它们.从 @MainActor 调用时
// strict concurrency 会报跨 edge sending 错误.@preconcurrency 让编译器对未 audit Sendable
// 的外部依赖放宽检查,这是 Swift 6 跟 pre-Swift 6 SPM 包共存的官方推荐做法.
@preconcurrency import WhisperKit

/// WhisperKit ASR provider — pull 模型,provider 通过 `AudioStreamTranscriber` 让 WhisperKit
/// 内部自管麦克风(D1 revised).Phase 2D 实现,代码骨架对照 `docs/asr-provider-design.md` 的
/// "WhisperKit Fit" 节 + `docs/whisperkit-streaming-spike.md` 的 spike 实测发现.
@MainActor
final class WhisperKitProvider: ASRProvider {

    nonisolated static let id: ASREngine = .whisperKit
    let displayName = "WhisperKit large-v3"

    private(set) var modelStatus: ASRModelStatus = .missing

    // MARK: - 引擎实例 + 流式 transcriber

    private var pipe: WhisperKit?
    private var streamer: AudioStreamTranscriber?
    private var streamTask: Task<Void, Never>?

    // MARK: - 累积文本

    /// 已确认段累加(随 confirmedSegments 增长)— 稳定文本,fire onFinal 的源
    private var confirmedAccum: String = ""

    /// 未确认 + currentText 拼接 — 随 partial 变化的尾部,跟 onPartial 等价
    private var liveTail: String = ""

    // MARK: - Caller callback

    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((ASRError) -> Void)?

    // MARK: - 模型配置

    private static let modelName = "openai_whisper-large-v3-v20240930_626MB"

    /// 生产模型路径 — Application Support,**不污染** `~/Documents/huggingface/`(spike doc 已警告)
    private static var modelFolder: URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        return appSupport.appendingPathComponent("VoiceBee/models")
    }

    // MARK: - ASRProvider

    var fullTranscript: String {
        // W6: confirmed + 最新 partial 拼接,跟 onPartial 看到的等价
        let parts = [confirmedAccum, liveTail].filter { !$0.isEmpty }
        return parts.joined(separator: " ")
    }

    func prepare(progress: @Sendable @escaping (ASRPrepareEvent) -> Void) async throws {
        // W9:WhisperKit 内部下载无公开 progress hook,只发 downloadStarted + loading + ready
        progress(.downloadStarted(sizeBytes: 626_000_000))
        modelStatus = .downloading(progress: 0)

        let config = WhisperKitConfig(
            model: Self.modelName,
            modelFolder: Self.modelFolder.path,
            verbose: false,
            logLevel: .info,
            prewarm: true
        )

        do {
            // W8:不预检模型存在性,WhisperKit 内部处理 missing → 自动下载
            pipe = try await WhisperKit(config)
            modelStatus = .loading
            progress(.loading)
            // lazy init:必须显式 loadModels() 才会装上 tokenizer + Core ML
            try await pipe!.loadModels()
            modelStatus = .ready
            progress(.ready)
        } catch {
            let asrError = ASRError.modelLoadFailed(error)
            modelStatus = .failed(asrError)
            throw asrError
        }
    }

    func startStreaming(
        language: String,
        vocabHint: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (ASRError) -> Void
    ) async throws {
        guard let pipe, let tokenizer = pipe.tokenizer, modelStatus == .ready else {
            onError(.modelMissing)
            throw ASRError.modelMissing
        }

        // 重置状态 + 接 callback
        confirmedAccum = ""
        liveTail = ""
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError

        // promptTokens 暂不注入 — PoC E 节验证 v1.0.0 死胡同;后续 hook 留给 VocabPostprocessor
        _ = vocabHint
        let options = DecodingOptions(
            task: .transcribe,
            language: language.hasPrefix("zh") ? "zh" : "en",
            temperature: 0.0,
            detectLanguage: false
        )

        // W3:每次 startStreaming 重建 transcriber,状态隔离
        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: options,
            stateChangeCallback: { [weak self] _, newState in
                // @Sendable closure(actor 内部 RunLoop, 非 main)
                // 边界处提取 Sendable primitives + W7 清洗 special tokens,再 hop 主 actor
                let confirmed = newState.confirmedSegments
                    .map { Self.cleanText($0.text) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let unconfirmed = newState.unconfirmedSegments
                    .map { Self.cleanText($0.text) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                let current = Self.cleanText(newState.currentText)
                Task { @MainActor [weak self] in
                    self?.processStateChange(
                        confirmed: confirmed,
                        unconfirmed: unconfirmed,
                        current: current
                    )
                }
            }
        )
        self.streamer = transcriber

        // W11:Task 内 catch transcribe error,fire onError 而非 throw 到 caller
        streamTask = Task { [weak self] in
            do {
                try await transcriber.startStreamTranscription()
            } catch is CancellationError {
                // 正常 cancel,不报错
                return
            } catch {
                let nsError = error as NSError
                await MainActor.run {
                    self?.onError?(.underlying(nsError))
                }
            }
        }
    }

    func stopStreaming() async {
        // W4 主路:让 transcribe loop 自然退出(state.isRecording = false)
        if let streamer {
            await streamer.stopStreamTranscription()
        }

        // W5:短录音(<12s)永远没 confirmed segment,强制把当前 fullTranscript 提升为 final
        // 即使有 confirmed segment,这里 fire 一次让 VoiceEngine 拿到最后快照(processStateChange
        // 已 fire 过的 onFinal 是基于 confirmedAccum,这里再 fire 是 superset)
        let combined = fullTranscript
        if !combined.isEmpty {
            onFinal?(combined)
        }
        // 不清 callback / streamer — task 内 caller 仍在 await 自然完成
    }

    func cancel() {
        // W4 兜底:stopStreamTranscription(主路) + streamTask.cancel(兜底)
        if let streamer {
            // 同步 cancel,不能 await,fire-and-forget Task
            let s = streamer
            Task { await s.stopStreamTranscription() }
        }
        streamTask?.cancel()
        streamTask = nil
        streamer = nil
        confirmedAccum = ""
        liveTail = ""
        onPartial = nil
        onFinal = nil
        onError = nil
    }

    // MARK: - Internal

    /// 处理 transcriber state 变化(在主 actor 上)
    private func processStateChange(confirmed: String, unconfirmed: String, current: String) {
        // 1. confirmed 段变化 → 更新累加 + fire onFinal(增量)
        if !confirmed.isEmpty, confirmed != confirmedAccum {
            confirmedAccum = confirmed
            onFinal?(confirmed)
        }

        // 2. liveTail = unconfirmed + current,过滤 "Waiting for speech..." 哨兵
        let tailParts = [unconfirmed, current]
            .filter { !$0.isEmpty && $0 != "Waiting for speech..." }
        let newTail = tailParts.joined(separator: " ")

        if newTail != liveTail {
            liveTail = newTail
            // 发完整快照(confirmedAccum + liveTail)给 onPartial,跟 fullTranscript 等价
            let partialSnapshot = fullTranscript
            if !partialSnapshot.isEmpty {
                onPartial?(partialSnapshot)
            }
        }
    }

    // MARK: - Static helpers

    /// 清洗 WhisperKit 输出里的 special token 控制符(spike doc D.2 发现的生产坑).
    /// 例:`"<|zh|><|transcribe|><|0.00|>今天 VoiceBee<|2.50|>"` → `"今天 VoiceBee"`
    nonisolated private static func cleanText(_ raw: String) -> String {
        raw.replacingOccurrences(
            of: #"<\|[^|]+\|>"#,
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
