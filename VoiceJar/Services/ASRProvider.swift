import Foundation

// MARK: - Engine identity

/// ASR 引擎身份 — 用于设置面板持久化 + UI 切换
enum ASREngine: String, Codable, CaseIterable, Sendable {
    case sfSpeech
    case whisperKit
}

// MARK: - Model status (D4)

/// 模型就绪状态 — UI 用于显示状态条 / 禁用录音按钮
enum ASRModelStatus: Equatable {
    case notRequired                          // SFSpeech 不需要下载模型
    case missing                              // WhisperKit, 模型未下载
    case downloading(progress: Double)        // 0.0...1.0
    case loading                              // 已下载, Core ML 加载中
    case ready
    case failed(ASRError)
}

// MARK: - Prepare progress (D7)

/// `prepare()` 过程事件 — 跨 actor 传递(Sendable)
enum ASRPrepareEvent: Sendable {
    case downloadStarted(sizeBytes: Int64)
    case downloadProgress(fraction: Double)
    case loading
    case ready
}

// MARK: - Unified error (D5)

/// 统一 ASR 错误 — 消除上层依赖 framework-specific NSError code(SFSpeech code 1110 等)
enum ASRError: LocalizedError {
    case unavailable                          // 引擎不可用(framework 自身故障)
    case unauthorized                         // 语音识别或麦克风权限被拒
    case modelMissing                         // WhisperKit 模型未下载
    case modelLoadFailed(any Error)
    case noSpeechDetected                     // 过滤 SFSpeech code 1110 / WhisperKit silence
    case underlying(any Error)                // 兜底

    var errorDescription: String? {
        switch self {
        case .unavailable:            "语音识别服务不可用"
        case .unauthorized:           "缺少语音识别或麦克风权限,请在系统设置中授权"
        case .modelMissing:           "WhisperKit 模型未下载,请前往设置下载"
        case .modelLoadFailed(let e): "模型加载失败: \(e.localizedDescription)"
        case .noSpeechDetected:       nil      // 上层应忽略,不显示
        case .underlying(let e):      e.localizedDescription
        }
    }
}

extension ASRError: Equatable {
    static func == (lhs: ASRError, rhs: ASRError) -> Bool {
        switch (lhs, rhs) {
        case (.unavailable, .unavailable),
             (.unauthorized, .unauthorized),
             (.modelMissing, .modelMissing),
             (.noSpeechDetected, .noSpeechDetected):
            return true
        case let (.modelLoadFailed(a), .modelLoadFailed(b)):
            return (a as NSError) == (b as NSError)
        case let (.underlying(a), .underlying(b)):
            return (a as NSError) == (b as NSError)
        default:
            return false
        }
    }
}

// MARK: - Protocol (D1 revised — provider 自管 mic, VoiceEngine 协调者)

/// ASR 引擎抽象 — 每个 provider 全权管理自己的音频管线(mic capture / buffer / 转录 /
/// special-token 清洗),VoiceEngine 仅负责调起停 + 消费回调.
///
/// 设计源:`docs/asr-provider-design.md`(D1 revised 2026-05-12)
@MainActor
protocol ASRProvider: AnyObject {

    /// 引擎身份(设置持久化用)— 类级别常量,不绑 actor
    nonisolated static var id: ASREngine { get }

    /// UI 显示名(中文)
    var displayName: String { get }

    /// 当前模型就绪状态
    var modelStatus: ASRModelStatus { get }

    /// 预热:权限请求 / 模型下载 / Core ML load / prewarm.
    /// SFSpeech 秒级返回,WhisperKit 7-300s.
    /// `progress` 在 provider 内部触发,可跨 actor(Sendable).
    func prepare(progress: @Sendable @escaping (ASRPrepareEvent) -> Void) async throws

    /// 开启流式 session — provider 内部起 mic + ASR,开始转录.
    /// 调用前必须 `modelStatus == .ready`.
    /// - `onPartial` / `onFinal` 收到的字符串已清洗 special tokens(provider 责任)
    /// - 60s rotation / VAD / buffer 管理等实现细节由 provider 内部处理
    func startStreaming(
        language: String,
        vocabHint: [String],
        onPartial: @escaping (String) -> Void,
        onFinal: @escaping (String) -> Void,
        onError: @escaping (ASRError) -> Void
    ) async throws

    /// 用户主动结束录音(松开 hotkey)— 停麦克 + 让最后段 finalize.
    /// 调用后 `onFinal` 仍可能再 fire 1 次.
    func stopStreaming() async

    /// 立即取消(Esc)— 停麦克,丢弃 in-flight,清 callback.
    func cancel()

    /// 当前累计完整文本(已 finalize 段 + 当前 best),special tokens 已清洗
    var fullTranscript: String { get }
}
