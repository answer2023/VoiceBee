import AVFoundation
import Foundation
import Speech

/// 语音识别服务 — 支持文件识别和流式实时识别
/// 仅从主线程调用（由 VoiceEngine @MainActor 保证）
final class SpeechRecognizer {
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var streamingRequest: SFSpeechAudioBufferRecognitionRequest?
    private var currentLanguage: String

    // 会话轮换：SFSpeechRecognizer 单次约 60s 限制，超过会静默失败。
    // rotate() 把已识别文本存到 finalizedSegments，重开 request 继续接收 buffer。
    private var finalizedSegments: [String] = []
    private var currentBestText: String = ""
    private var contextualStringsCache: [String] = []
    private var partialCallback: ((String) -> Void)?
    private var finalCallback: ((String) -> Void)?
    private var errorCallback: ((Error) -> Void)?
    private var activeSessionToken: UUID?  // 过滤被 rotate 替换的旧 session 残余回调

    /// 当前累计完整文本（已 finalize 的段 + 当前 session 的 best）
    var fullTranscript: String {
        let parts = finalizedSegments + (currentBestText.isEmpty ? [] : [currentBestText])
        return parts.joined(separator: " ")
    }

    init(language: String = "zh-Hans") {
        self.currentLanguage = language
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// 切换识别语言
    func setLanguage(_ language: String) {
        guard language != currentLanguage else { return }
        currentLanguage = language
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: language))
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }

    /// 请求语音识别权限
    static func requestAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - 流式实时识别

    /// 开始流式识别，返回 partial results 通过回调
    /// - Parameter contextualStrings: 词典专名，注入识别引擎以提升专名识别准确率
    func startStreaming(contextualStrings: [String] = [],
                        onPartialResult: @escaping (String) -> Void,
                        onFinalResult: @escaping (String) -> Void,
                        onError: @escaping (Error) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            onError(RecognitionError.unavailable)
            return
        }

        // 重置会话状态
        finalizedSegments = []
        currentBestText = ""
        contextualStringsCache = contextualStrings
        partialCallback = onPartialResult
        finalCallback = onFinalResult
        errorCallback = onError

        startSession()
    }

    /// 启动一个新的 ASR session（用于初次启动 + 轮换）
    private func startSession() {
        guard let recognizer, recognizer.isAvailable else {
            errorCallback?(RecognitionError.unavailable)
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if !contextualStringsCache.isEmpty {
            request.contextualStrings = contextualStringsCache
        }
        streamingRequest = request

        let token = UUID()
        activeSessionToken = token

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, self.activeSessionToken == token else { return }
            if let error {
                self.errorCallback?(error)
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            self.currentBestText = text
            let combined = self.fullTranscript
            if result.isFinal {
                self.finalCallback?(combined)
            } else {
                self.partialCallback?(combined)
            }
        }
    }

    /// 轮换会话：把当前文本归档为已完成段，重启新 session 继续接收音频
    /// 用于绕过 SFSpeech 单次 ~60s 限制
    func rotate() {
        guard streamingRequest != nil else { return }
        if !currentBestText.isEmpty {
            finalizedSegments.append(currentBestText)
        }
        currentBestText = ""
        // 收尾旧 session
        streamingRequest?.endAudio()
        recognitionTask?.cancel()
        streamingRequest = nil
        recognitionTask = nil
        // 立即开新 session 接管后续 buffer
        startSession()
    }

    /// 往流式识别中追加音频数据
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        streamingRequest?.append(buffer)
    }

    /// 结束流式识别（告知没有更多音频）
    func finishStreaming() {
        streamingRequest?.endAudio()
        streamingRequest = nil
    }

    // MARK: - 文件识别（保留备用）

    /// 从音频文件识别文字
    func recognize(url: URL) async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionError.unavailable
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = false
            request.addsPunctuation = true

            var resumed = false
            recognitionTask = recognizer.recognitionTask(with: request) { result, error in
                guard !resumed else { return }
                if let error {
                    resumed = true
                    continuation.resume(throwing: error)
                    return
                }
                guard let result, result.isFinal else { return }
                resumed = true
                continuation.resume(returning: result.bestTranscription.formattedString)
            }
        }
    }

    /// 取消当前识别（清除所有状态）
    func cancel() {
        activeSessionToken = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        streamingRequest?.endAudio()
        streamingRequest = nil
        finalizedSegments = []
        currentBestText = ""
        partialCallback = nil
        finalCallback = nil
        errorCallback = nil
    }

    enum RecognitionError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            switch self {
            case .unavailable: "语音识别不可用，请检查系统设置"
            }
        }
    }
}
