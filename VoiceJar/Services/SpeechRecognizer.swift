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

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if !contextualStrings.isEmpty {
            request.contextualStrings = contextualStrings
        }

        streamingRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { result, error in
            if let error {
                onError(error)
                return
            }
            guard let result else { return }
            let text = result.bestTranscription.formattedString
            if result.isFinal {
                onFinalResult(text)
            } else {
                onPartialResult(text)
            }
        }
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

    /// 取消当前识别
    func cancel() {
        recognitionTask?.cancel()
        recognitionTask = nil
        streamingRequest?.endAudio()
        streamingRequest = nil
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
