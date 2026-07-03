import AVFoundation
import Foundation
import Speech

/// SFSpeech ASR provider — 把现有 `SpeechRecognizer + AudioRecorder` 的流式逻辑合并进
/// provider 内部(D1 revised:provider 自管 mic),VoiceEngine 退化为协调者.
///
/// 设计源:`docs/asr-provider-design.md` "SFSpeech Fit" 节
/// audio thread 跟主 actor 共享 streamingRequest 的 box.
///
/// 历史教训(2026-05-13 Thread 7 crash):原方案用 `nonisolated(unsafe) var
/// streamingRequest` 让 installTap closure 直接 `self?.streamingRequest?.append`,
/// 编译通过但 runtime 撞 `_dispatch_assert_queue_fail` — Swift 6 对 @MainActor class
/// 的 `var` 访问即使标 nonisolated(unsafe) 仍可能插入 main-queue assertion.
/// 修复:用独立 @unchecked Sendable box,audio thread closure 仅捕获 box,完全不经 self.
private final class StreamingRequestBox: @unchecked Sendable {
    var request: SFSpeechAudioBufferRecognitionRequest?
}

@MainActor
final class SFSpeechProvider: ASRProvider {

    nonisolated static let id: ASREngine = .sfSpeech
    let displayName = "macOS Speech(内置)"

    private(set) var modelStatus: ASRModelStatus = .notRequired

    // MARK: - 麦克风(D1 revised:provider 自管,内化原 AudioRecorder 逻辑)

    private let audioEngine = AVAudioEngine()

    // MARK: - ASR session state

    /// 主 actor 持有的当前 streaming request 引用(逻辑状态用)
    private var streamingRequest: SFSpeechAudioBufferRecognitionRequest?

    /// audio thread 跟主 actor 之间的 request 桥 — installTap closure 只捕获此 box,
    /// 不引用 self,消除 @MainActor class 在 audio thread 上被访问触发的 dispatch assert.
    /// SFSpeechAudioBufferRecognitionRequest.append(_:) 本身线程安全(Apple 文档).
    private let requestBox = StreamingRequestBox()

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var activeSessionToken: UUID?
    private var rotationTimer: Timer?

    /// SFSpeech 单 session 约 60s 上限,55s 触发 rotation 留余量(D3 — 完全 provider 内部)
    private let rotationInterval: TimeInterval = 55

    // MARK: - 累积文本(等价于原 SpeechRecognizer 行为)

    private var finalizedSegments: [String] = []
    private var currentBestText: String = ""
    private var contextualStringsCache: [String] = []

    // MARK: - Callbacks(caller 给的 closure,@MainActor 隔离)

    private var onPartial: ((String) -> Void)?
    private var onFinal: ((String) -> Void)?
    private var onError: ((ASRError) -> Void)?

    // MARK: - ASRProvider

    var fullTranscript: String {
        let parts = finalizedSegments + (currentBestText.isEmpty ? [] : [currentBestText])
        return parts.joined(separator: " ")
    }

    func prepare(progress: @Sendable @escaping (ASRPrepareEvent) -> Void) async throws {
        // P2 决策 A:prepare 只做 SFSpeech 授权;mic 权限留给首次 audioEngine.start() 自然触发
        let status = await Self.requestSpeechAuthorization()
        guard status == .authorized else {
            modelStatus = .failed(.unauthorized)
            throw ASRError.unauthorized
        }
        modelStatus = .ready
        progress(.ready)
    }

    func startStreaming(
        language: String,
        vocabHint: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (ASRError) -> Void
    ) async throws {
        // 1. 重置状态 + 接住 callback
        finalizedSegments = []
        currentBestText = ""
        contextualStringsCache = vocabHint
        self.onPartial = onPartial
        self.onFinal = onFinal
        self.onError = onError

        // 2. 按 session 语言创建 recognizer(protocol 设计:language 每次 startStreaming 传入)
        let locale = Locale(identifier: language)
        let resolved = SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let resolved, resolved.isAvailable else {
            throw ASRError.unavailable
        }
        recognizer = resolved

        // 3. 启动 ASR session(创建 streamingRequest + recognitionTask)
        startSession()

        // 4. D3:rotation timer 隐藏在 provider 内部
        // @Sendable 打破 @MainActor 继承(timer fire 时 RunLoop callback 不保证在 main isolation context)
        rotationTimer = Timer.scheduledTimer(withTimeInterval: rotationInterval, repeats: true) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.internalRotate()
            }
        }

        // 5. 起麦克风 + tap — closure 仅捕获 requestBox(@unchecked Sendable),
        //    不通过 self,彻底避开 @MainActor class 跨线程访问的 dispatch assertion
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        let box = requestBox
        // ⚠️ @Sendable 显式打破 isolation 继承:installTap closure 定义在 @MainActor 方法内,
        // 默认会继承 @MainActor isolation,audio thread invoke 时 runtime 撞 dispatch_assert.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            box.request?.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // mic 起不来 → 回滚 ASR session + rotation timer,返回错误
            audioEngine.inputNode.removeTap(onBus: 0)
            recognitionTask?.cancel()
            recognitionTask = nil
            streamingRequest = nil
            requestBox.request = nil
            rotationTimer?.invalidate()
            rotationTimer = nil
            throw ASRError.underlying(error)
        }
    }

    func stopStreaming() async {
        // P3 决策 A:停麦克 + endAudio,立即返回;onFinal 在后续 SFSpeech callback 自然到
        // removeTap 必须无条件执行(无 tap 时是安全 no-op):engine 会因输入设备变更
        // (AirPods/USB 麦克风 断连)自行停止且不清 tap,此时 isRunning=false,
        // 若跳过 removeTap,下次 installTap 撞已有 tap 会抛不可捕获的 ObjC 异常直接崩溃
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        rotationTimer?.invalidate()
        rotationTimer = nil
        streamingRequest?.endAudio()
        requestBox.request = nil  // 切断 audio thread 进一步 append(tap 已 remove,防御性)
        // 不清 callback / 不清 finalizedSegments — onFinal 最后一次可能仍要 fire
    }

    func cancel() {
        // Esc 全链路取消:停麦克 + 取消 ASR + 清所有 in-flight 状态
        activeSessionToken = nil
        // 同 stopStreaming:removeTap 无条件执行,防 engine 自停后 tap 残留
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        rotationTimer?.invalidate()
        rotationTimer = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        streamingRequest?.endAudio()
        streamingRequest = nil
        requestBox.request = nil
        finalizedSegments = []
        currentBestText = ""
        onPartial = nil
        onFinal = nil
        onError = nil
    }

    // MARK: - Internal

    /// 启动单次 ASR session — 用于初次开启 + rotation
    private func startSession() {
        guard let recognizer, recognizer.isAvailable else {
            onError?(.unavailable)
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if !contextualStringsCache.isEmpty {
            request.contextualStrings = contextualStringsCache
        }
        streamingRequest = request
        requestBox.request = request  // 同步桥 — audio thread 通过 box 拿当前 request

        let token = UUID()
        activeSessionToken = token

        // @Sendable 显式:SFSpeech callback 在 internal queue invoke,closure 不能继承 @MainActor
        recognitionTask = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            // SFSpeech callback 在 internal queue,跨 actor 时只发 Sendable primitives
            // (String / Bool / UUID / NSError),ASRError 在主 actor 内部再构造
            if let error {
                let nsError = error as NSError
                Task { @MainActor [weak self] in
                    self?.handleError(nsError, sessionToken: token)
                }
                return
            }
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { @MainActor [weak self] in
                    self?.handleResult(text: text, isFinal: isFinal, sessionToken: token)
                }
            }
        }
    }

    /// 处理 ASR result — 在主 actor,过滤被 rotate 替换的旧 session 残余回调
    private func handleResult(text: String, isFinal: Bool, sessionToken: UUID) {
        guard sessionToken == activeSessionToken else { return }
        currentBestText = text
        let combined = fullTranscript
        if isFinal {
            onFinal?(combined)
        } else {
            onPartial?(combined)
        }
    }

    /// 处理 ASR error — 映射到统一 ASRError(D5)
    private func handleError(_ nsError: NSError, sessionToken: UUID) {
        guard sessionToken == activeSessionToken else { return }
        if nsError.code == 1110 {
            // SFSpeech "No speech detected" — 不算错误,上层会忽略
            onError?(.noSpeechDetected)
        } else {
            onError?(.underlying(nsError))
        }
    }

    /// Rotation:把当前 best 归档到 finalizedSegments,重启新 session 接管后续 buffer
    /// (SFSpeech 单 session 60s 限制的解法,藏在 provider 内部 — D3)
    private func internalRotate() {
        guard streamingRequest != nil else { return }
        if !currentBestText.isEmpty {
            finalizedSegments.append(currentBestText)
        }
        currentBestText = ""
        // 收尾旧 session(旧 callback 残余通过 activeSessionToken 比较被过滤)
        streamingRequest?.endAudio()
        recognitionTask?.cancel()
        streamingRequest = nil
        requestBox.request = nil  // 防御:audio thread 看到 nil 时 noop;startSession 会立即重设
        recognitionTask = nil
        // 立即开新 session 接管 audio tap 的后续 buffer
        startSession()
    }

    // MARK: - Static helpers

    private static func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            // @Sendable 显式:TCC callback 在 internal queue,closure 不能继承 @MainActor
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }
}
