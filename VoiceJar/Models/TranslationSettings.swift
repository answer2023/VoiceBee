import Foundation
import CoreGraphics

/// 用户日常工作语言 — 多选；注入 LLM system prompt 头部影响润色判断
/// 也作为口述翻译的目标语言候选
enum WorkingLanguage: String, CaseIterable, Codable, Identifiable {
    case zhHans, zhHant, en, ja, ko, fr, de, es, it, pt, ru, ar, vi, th, hi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .es: return "Español"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .ar: return "العربية"
        case .vi: return "Tiếng Việt"
        case .th: return "ไทย"
        case .hi: return "हिन्दी"
        }
    }

    /// 给 LLM 用的语言名（英文，更稳定）
    var promptName: String {
        switch self {
        case .zhHans: return "Simplified Chinese"
        case .zhHant: return "Traditional Chinese"
        case .en: return "English"
        case .ja: return "Japanese"
        case .ko: return "Korean"
        case .fr: return "French"
        case .de: return "German"
        case .es: return "Spanish"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        case .ar: return "Arabic"
        case .vi: return "Vietnamese"
        case .th: return "Thai"
        case .hi: return "Hindi"
        }
    }
}

/// 口述翻译的触发键 — 录音中单击该键标记本次走翻译管线
enum TranslationTrigger: String, CaseIterable, Codable, Identifiable {
    case shift, control, option, fn, disabled

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .shift: return "Shift"
        case .control: return "Control"
        case .option: return "Option"
        case .fn: return "Fn"
        case .disabled: return "不启用"
        }
    }

    var symbol: String {
        switch self {
        case .shift: return "⇧"
        case .control: return "⌃"
        case .option: return "⌥"
        case .fn: return "Fn"
        case .disabled: return "—"
        }
    }
}

/// 口述翻译 + 工作语言设置
@Observable
final class TranslationSettings {
    /// load() 里赋值触发 didSet→save() 会用未加载完的默认值清掉磁盘配置,load 期间压制
    private var isLoading = false

    /// 注入 defaults 供测试隔离(生产用 .standard)
    private let defaults: UserDefaults

    var workingLanguages: Set<WorkingLanguage> = [.zhHans, .en] {
        didSet { save() }
    }
    var targetLanguage: WorkingLanguage? {  // nil = 不启用翻译模式
        didSet { save() }
    }
    var trigger: TranslationTrigger = TranslationSettings.smartDefaultTrigger {
        didSet { save() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    /// 翻译模式当前是否实际可被触发（目标语言 + 触发键 都已配置）
    var isActiveForRecording: Bool {
        targetLanguage != nil && trigger != .disabled
    }

    /// 判断 Rime / Squirrel 输入法存在 → 默认改用 Control 避免 Shift 切换 IME 冲突
    private static var smartDefaultTrigger: TranslationTrigger {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let imePaths = [
            home + "/Library/Rime",
            home + "/Library/Input Methods/Squirrel.app",
            "/Library/Input Methods/Squirrel.app",
        ]
        let hasIME = imePaths.contains { fm.fileExists(atPath: $0) }
        return hasIME ? .control : .shift
    }

    /// 给定主录音键的修饰键集合，返回与之冲突的触发键集合（应在 UI 灰显）
    static func conflictingTriggers(mainModifiers: CGEventFlags) -> Set<TranslationTrigger> {
        var result: Set<TranslationTrigger> = []
        if mainModifiers.contains(.maskShift) { result.insert(.shift) }
        if mainModifiers.contains(.maskControl) { result.insert(.control) }
        if mainModifiers.contains(.maskAlternate) { result.insert(.option) }
        if mainModifiers.contains(.maskSecondaryFn) { result.insert(.fn) }
        return result
    }

    /// CGEventFlags mask for the trigger; nil 表示禁用
    var triggerMask: CGEventFlags? {
        switch trigger {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .fn: return .maskSecondaryFn
        case .disabled: return nil
        }
    }

    private func save() {
        guard !isLoading else { return }
        let d = defaults
        d.set(workingLanguages.map(\.rawValue), forKey: "translation_workingLanguages")
        d.set(targetLanguage?.rawValue ?? "", forKey: "translation_targetLanguage")
        d.set(trigger.rawValue, forKey: "translation_trigger")
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        let d = defaults
        if let arr = d.stringArray(forKey: "translation_workingLanguages") {
            let parsed = Set(arr.compactMap { WorkingLanguage(rawValue: $0) })
            if !parsed.isEmpty { workingLanguages = parsed }
        }
        if let s = d.string(forKey: "translation_targetLanguage"), !s.isEmpty,
           let lang = WorkingLanguage(rawValue: s) {
            targetLanguage = lang
        }
        if let s = d.string(forKey: "translation_trigger"),
           let t = TranslationTrigger(rawValue: s) {
            trigger = t
        }
    }
}
