import Carbon.HIToolbox
import Foundation
import SwiftUI

/// 全局应用状态
@Observable
class AppState {
    var isRecording = false
    var isProcessing = false
    var rawTranscription = ""
    var polishedText = ""
    var liveText = ""
    var statusMessage = ""
    var errorMessage: String?
    var history: [TranscriptionRecord] = []
    var isTranslating = false
    var translatedText = ""
    var inputMode: InputMode = .universal
    var polishMode: PolishMode = .instant
    var polishSettings = PolishSettings(keyPrefix: "polish")
    var translateSettings = PolishSettings(keyPrefix: "translate")

    /// 识别语言
    var recognitionLanguage: RecognitionLanguage {
        didSet {
            UserDefaults.standard.set(recognitionLanguage.rawValue, forKey: "recognition_language")
        }
    }

    /// 当前快捷键配置
    var hotkey: HotkeyCombo {
        didSet {
            hotkey.save()
            statusMessage = "按住 \(hotkey.displayName) 开始说话"
        }
    }

    /// 翻译快捷键
    var translateHotkey: HotkeyCombo {
        didSet { translateHotkey.saveAsTranslateHotkey() }
    }

    /// 翻译目标语言
    var translateTargetLang: TranslateTargetLanguage {
        didSet {
            UserDefaults.standard.set(translateTargetLang.rawValue, forKey: "translate_target_lang")
        }
    }

    init() {
        let hk = HotkeyCombo.load()
        self.hotkey = hk
        self.statusMessage = "按住 \(hk.displayName) 开始说话"

        let langCode = UserDefaults.standard.string(forKey: "recognition_language") ?? "zh-Hans"
        self.recognitionLanguage = RecognitionLanguage(rawValue: langCode) ?? .chineseSimplified

        self.translateHotkey = HotkeyCombo.loadTranslateHotkey()
        let targetLang = UserDefaults.standard.string(forKey: "translate_target_lang") ?? "auto"
        self.translateTargetLang = TranslateTargetLanguage(rawValue: targetLang) ?? .auto
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

// MARK: - 快捷键配置

struct HotkeyCombo: Equatable {
    var keyCode: Int  // Carbon virtual key code, -1 表示纯修饰键
    var modifiers: CGEventFlags

    /// 是否是 Fn 单键模式
    var isFnOnly: Bool { keyCode == -1 && modifiers == .maskSecondaryFn }

    /// 预设快捷键
    static let fn = HotkeyCombo(keyCode: -1, modifiers: .maskSecondaryFn)
    static let optionSpace = HotkeyCombo(keyCode: kVK_Space, modifiers: .maskAlternate)
    static let controlSpace = HotkeyCombo(keyCode: kVK_Space, modifiers: .maskControl)
    static let fnF5 = HotkeyCombo(keyCode: kVK_F5, modifiers: .maskSecondaryFn)

    static let presets: [(name: String, combo: HotkeyCombo)] = [
        ("Fn (按住说话)", .fn),
        ("⌥ Space (Option+空格)", .optionSpace),
        ("⌃ Space (Control+空格)", .controlSpace),
        ("Fn + F5", .fnF5),
    ]

    var displayName: String {
        if isFnOnly { return "Fn" }
        var parts: [String] = []
        if modifiers.contains(.maskControl) { parts.append("⌃") }
        if modifiers.contains(.maskAlternate) { parts.append("⌥") }
        if modifiers.contains(.maskShift) { parts.append("⇧") }
        if modifiers.contains(.maskCommand) { parts.append("⌘") }
        if modifiers.contains(.maskSecondaryFn) { parts.append("Fn+") }
        parts.append(keyName)
        return parts.joined()
    }

    private var keyName: String {
        switch keyCode {
        case -1: return ""
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "Delete"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        default:
            // 尝试通过 Carbon key code 转换为字符
            if let char = keyCodeToChar(keyCode) {
                return char.uppercased()
            }
            return "Key(\(keyCode))"
        }
    }

    private func keyCodeToChar(_ code: Int) -> String? {
        // 使用 ASCII 键盘布局，避免中文输入法下转换失败
        guard let sourceRef = TISCopyCurrentASCIICapableKeyboardLayoutInputSource() else { return nil }
        let source = sourceRef.takeRetainedValue()
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layoutData).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            UCKeyTranslate(ptr, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           UInt32(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }

    func matches(keyCode: Int64, flags: CGEventFlags) -> Bool {
        return keyCode == Int64(self.keyCode) && flags.contains(modifiers)
    }

    /// 严格匹配：要求修饰键完全一致（防止 ⌘⌥T 误触发 ⌥T）
    func matchesExact(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return keyCode == Int64(self.keyCode) && flags.intersection(relevant) == modifiers.intersection(relevant)
    }

    func modifierStillHeld(flags: CGEventFlags) -> Bool {
        return flags.contains(modifiers)
    }

    // MARK: - 持久化

    func save() {
        UserDefaults.standard.set(keyCode, forKey: "hotkey_keyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "hotkey_modifiers")
    }

    static func load() -> HotkeyCombo {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "hotkey_keyCode") != nil else {
            return .optionSpace  // 默认 ⌥Space（Fn/Globe 键在新 Mac 上被系统拦截）
        }
        let code = defaults.integer(forKey: "hotkey_keyCode")
        let mods = CGEventFlags(rawValue: UInt64(defaults.integer(forKey: "hotkey_modifiers")))
        return HotkeyCombo(keyCode: code, modifiers: mods)
    }

    // MARK: - 翻译快捷键持久化

    func saveAsTranslateHotkey() {
        UserDefaults.standard.set(keyCode, forKey: "translate_hotkey_keyCode")
        UserDefaults.standard.set(Int(modifiers.rawValue), forKey: "translate_hotkey_modifiers")
    }

    static func loadTranslateHotkey() -> HotkeyCombo {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "translate_hotkey_keyCode") != nil else {
            return HotkeyCombo(keyCode: 17, modifiers: .maskAlternate)  // 默认 ⌥T
        }
        let code = defaults.integer(forKey: "translate_hotkey_keyCode")
        let mods = CGEventFlags(rawValue: UInt64(defaults.integer(forKey: "translate_hotkey_modifiers")))
        return HotkeyCombo(keyCode: code, modifiers: mods)
    }
}

/// 输入模式
enum InputMode: String, CaseIterable {
    case universal = "通用输入"
    case journal = "写入日志"
}

/// 润色模式
enum PolishMode: String, CaseIterable {
    case instant = "即时上屏"
    case structured = "润色上屏"

    var icon: String {
        switch self {
        case .instant: return "bolt.fill"
        case .structured: return "sparkles"
        }
    }

    mutating func toggle() {
        self = (self == .instant) ? .structured : .instant
    }
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
struct TranscriptionRecord: Identifiable {
    let id = UUID()
    let rawText: String
    let polishedText: String
    let timestamp: Date
    let duration: TimeInterval
}
