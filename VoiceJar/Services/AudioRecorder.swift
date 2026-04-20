import AVFoundation
import Foundation

/// 音频录制服务 — 使用 AVAudioEngine 实时录音，支持流式回调
class AudioRecorder {
    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var isRecording = false

    /// 音频缓冲回调 — 用于流式语音识别
    var onAudioBuffer: ((AVAudioPCMBuffer) -> Void)?

    /// 录音文件临时路径
    var recordingURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("voicejar_recording.wav")
    }

    /// 开始录音
    func startRecording() throws {
        // 清理旧文件
        try? FileManager.default.removeItem(at: recordingURL)

        let inputNode = engine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // 创建音频文件
        audioFile = try AVAudioFile(
            forWriting: recordingURL,
            settings: recordingFormat.settings
        )

        // 安装 tap 捕获音频数据
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak self] buffer, _ in
            try? self?.audioFile?.write(from: buffer)
            // 流式回调：把音频buffer同时送给语音识别
            self?.onAudioBuffer?(buffer)
        }

        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// 停止录音，返回录音文件 URL
    func stopRecording() -> URL? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
        isRecording = false

        // 验证文件存在
        guard FileManager.default.fileExists(atPath: recordingURL.path) else {
            return nil
        }
        return recordingURL
    }
}
