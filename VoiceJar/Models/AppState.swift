import Carbon.HIToolbox
import Foundation
import SwiftUI

/// 全局应用状态
@Observable
class AppState {
    var isRecording = false
    var isProcessing = false
    /// 暂停状态：所有全局快捷键拦截都禁用（菜单栏可切换）
    /// 持久化，避免重启后默默拦截快捷键让用户困惑
    var isPaused: Bool {
        didSet {
            UserDefaults.standard.set(isPaused, forKey: "is_paused")
            NotificationCenter.default.post(name: .pauseStateChanged, object: isPaused)
        }
    }
    var rawTranscription = ""
    var polishedText = ""
    var liveText = ""
    var statusMessage = ""
    var errorMessage: String?
    /// loadHistory() 里的赋值会触发 didSet→saveHistory(),启动时把刚读到的内容原样重写一遍 —— load 期间必须压制持久化
    private var isLoadingHistory = false
    var history: [TranscriptionRecord] = [] {
        didSet { saveHistory() }
    }
    var isTranslating = false
    var translatedText = ""
    var inputMode: InputMode = .universal
    var polishSettings = PolishSettings(keyPrefix: "polish")
    var translateSettings = PolishSettings(keyPrefix: "translate")
    let vocab = VocabStore()
    let stats = StatsStore()
    let outputStyle = OutputStyleSettings()
    let translation = TranslationSettings()

    private static let historyFileURL: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("VoiceBee", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    /// 在 record 列表中替换某条的润色文本（用于「重新润色」）
    func updateHistory(id: UUID, polishedText: String) {
        guard let idx = history.firstIndex(where: { $0.id == id }) else { return }
        history[idx].polishedText = polishedText
    }

    private func saveHistory() {
        guard !isLoadingHistory else { return }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(history)
            try data.write(to: Self.historyFileURL, options: .atomic)
        } catch {
            VJLog.log("❌ 保存失败: \(error)", prefix: "History")
        }
    }

    private func loadHistory() {
        guard FileManager.default.fileExists(atPath: Self.historyFileURL.path) else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            let data = try Data(contentsOf: Self.historyFileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            history = try decoder.decode([TranscriptionRecord].self, from: data)
        } catch {
            // decode 失败:把损坏文件挪到 .bak 保留现场,防止下一次 saveHistory() 原地覆盖
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = Self.historyFileURL.deletingLastPathComponent()
                .appendingPathComponent("history.json.corrupt-\(timestamp).bak")
            do {
                try FileManager.default.moveItem(at: Self.historyFileURL, to: backupURL)
                VJLog.log("❌ 加载失败,损坏文件已备份到 \(backupURL.lastPathComponent): \(error)", prefix: "History")
            } catch let moveError {
                VJLog.log("❌ 加载失败,且备份损坏文件也失败(原文件留在原位): \(error) / 备份错误: \(moveError)", prefix: "History")
            }
        }
    }

    /// 识别语言
    var recognitionLanguage: RecognitionLanguage {
        didSet {
            UserDefaults.standard.set(recognitionLanguage.rawValue, forKey: "recognition_language")
        }
    }

    /// ASR 引擎(SFSpeech / WhisperKit)— Phase 2F 引入
    var asrEngine: ASREngine {
        didSet {
            UserDefaults.standard.set(asrEngine.rawValue, forKey: "asr_engine")
            NotificationCenter.default.post(name: .asrEngineChanged, object: asrEngine)
        }
    }

    /// ASR 模型状态文字 — VoiceEngine 写,SettingsView 读.不持久化(仅 runtime UI 反馈)
    var asrModelStatusMessage: String = ""

    /// 当前快捷键配置(Phase 3-B: HotkeyCombo → Hotkey enum)
    var hotkey: Hotkey {
        didSet {
            hotkey.save()
            statusMessage = hotkey.mode == .toggle
                ? "按 \(hotkey.displayName) 切换录音"
                : "按住 \(hotkey.displayName) 开始说话"
        }
    }

    /// 翻译快捷键(强制 .hold mode,F2=C)
    var translateHotkey: Hotkey {
        didSet { translateHotkey.saveAsTranslateHotkey() }
    }

    /// "重复粘贴上次结果"快捷键(默认 ⌥⇧V,强制 .hold mode,F2=C)
    var repeatLastHotkey: Hotkey {
        didSet { repeatLastHotkey.saveAsRepeatLastHotkey() }
    }

    /// 翻译目标语言
    var translateTargetLang: TranslateTargetLanguage {
        didSet {
            UserDefaults.standard.set(translateTargetLang.rawValue, forKey: "translate_target_lang")
        }
    }

    init() {
        let hk = Hotkey.load()
        self.hotkey = hk
        self.isPaused = UserDefaults.standard.bool(forKey: "is_paused")
        self.statusMessage = hk.mode == .toggle
            ? "按 \(hk.displayName) 切换录音"
            : "按住 \(hk.displayName) 开始说话"

        let langCode = UserDefaults.standard.string(forKey: "recognition_language") ?? "zh-Hans"
        self.recognitionLanguage = RecognitionLanguage(rawValue: langCode) ?? .chineseSimplified

        let engineCode = UserDefaults.standard.string(forKey: "asr_engine") ?? ASREngine.sfSpeech.rawValue
        self.asrEngine = ASREngine(rawValue: engineCode) ?? .sfSpeech

        self.translateHotkey = Hotkey.loadTranslateHotkey()
        self.repeatLastHotkey = Hotkey.loadRepeatLastHotkey()
        let targetLang = UserDefaults.standard.string(forKey: "translate_target_lang") ?? "auto"
        self.translateTargetLang = TranslateTargetLanguage(rawValue: targetLang) ?? .auto

        loadHistory()
    }
}

/// 识别语言
enum RecognitionLanguage: String, CaseIterable {
    case chineseSimplified = "zh-Hans"
    case english = "en-US"
    case chineseTraditional = "zh-Hant"
    case japanese = "ja-JP"
    case korean = "ko-KR"

    var displayName: String {
        switch self {
        case .chineseSimplified: return "简体中文"
        case .english: return "English"
        case .chineseTraditional: return "繁體中文"
        case .japanese: return "日本語"
        case .korean: return "한국어"
        }
    }
}

/// 翻译目标语言
enum TranslateTargetLanguage: String, CaseIterable {
    case auto = "auto"
    case english = "English"
    case chinese = "中文"
    case japanese = "日本語"

    var displayName: String {
        switch self {
        case .auto: return "自动（中↔英）"
        case .english: return "English"
        case .chinese: return "中文"
        case .japanese: return "日本語"
        }
    }

    var promptDescription: String {
        switch self {
        case .auto: return "the opposite language (if source is Chinese, translate to English; if source is English/Japanese/Korean/other, translate to Simplified Chinese)"
        case .english: return "English"
        case .chinese: return "Simplified Chinese"
        case .japanese: return "Japanese"
        }
    }
}

// MARK: - 快捷键配置(Hotkey enum / HotkeyMode / ModifierKey 定义见 Hotkey.swift)

/// 输入模式
enum InputMode: String, CaseIterable {
    case universal = "通用输入"
    case journal = "写入日志"
}

/// 润色引擎
enum PolishEngine: String, CaseIterable, Sendable {
    case none = "不润色"
    case ollama = "Ollama (本地)"
    case ollamaCloud = "Ollama (云端)"
    case claude = "Claude"
    case deepseek = "DeepSeek"
    case gemini = "Gemini"
    case openaiCompatible = "OpenAI 兼容"

    var defaultModel: String {
        switch self {
        case .none: return ""
        case .ollama: return "qwen2.5:7b"
        case .ollamaCloud: return "gpt-oss:120b-cloud"
        case .claude: return "claude-sonnet-4-20250514"
        case .deepseek: return "deepseek-chat"
        case .gemini: return "gemini-2.0-flash"
        case .openaiCompatible: return "gpt-4o-mini"
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .none, .ollama, .ollamaCloud: return false
        default: return true
        }
    }
}

/// 转写记录
struct TranscriptionRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    let rawText: String
    var polishedText: String
    let timestamp: Date
    let duration: TimeInterval

    init(
        id: UUID = UUID(),
        rawText: String,
        polishedText: String,
        timestamp: Date,
        duration: TimeInterval
    ) {
        self.id = id
        self.rawText = rawText
        self.polishedText = polishedText
        self.timestamp = timestamp
        self.duration = duration
    }

    // 旧 history.json 缺字段 / 单条记录字段异常时,用 decodeIfPresent 全量容错(仅 rawText 必填)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.rawText = try c.decode(String.self, forKey: .rawText)
        self.polishedText = try c.decodeIfPresent(String.self, forKey: .polishedText) ?? ""
        self.timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        self.duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, rawText, polishedText, timestamp, duration
    }
}
