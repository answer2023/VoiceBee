import Foundation

/// 输出风格 — 用户决定 ASR 转写后润色的目标形态
/// 4 档由轻到重：raw（仅修标点）→ light（去口癖）→ structured（分点重组）→ formal（专业措辞）
enum OutputStyle: String, CaseIterable, Codable, Identifiable {
    case raw
    case light
    case structured
    case formal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .raw: return "原文"
        case .light: return "轻度润色"
        case .structured: return "清晰结构"
        case .formal: return "正式表达"
        }
    }

    var subtitle: String {
        switch self {
        case .raw: return "只补标点和必要分句，不改写不扩写。"
        case .light: return "去口癖、补标点，整理为可发送的自然文字。"
        case .structured: return "多个主题或步骤时，自动组织为分点列表。"
        case .formal: return "工作沟通和邮件场景，更专业更完整。"
        }
    }

    /// 卡片底部展示的样例 — 演示风格输出的「感觉」
    var samplePreview: String {
        switch self {
        case .raw:
            return "保留原始口语；嗯、那个等口癖被保留，仅必要时分句。"
        case .light:
            return "让转写听起来不像念稿——保留语气和表达习惯，但行文流畅。"
        case .structured:
            return "1. 主题一\n   a. 要点\n   b. 要点\n2. 主题二\n   a. 要点"
        case .formal:
            return "邮件场景自动识别问候 / 落款；不引入空泛客套。"
        }
    }

    var icon: String {
        switch self {
        case .raw: return "text.alignleft"
        case .light: return "wand.and.stars"
        case .structured: return "list.bullet.indent"
        case .formal: return "envelope"
        }
    }

    /// 注入给 LLM 的 system prompt
    var prompt: String {
        switch self {
        case .raw:
            return """
            你是中文语音转文字的最小化修正助手。只做：
            1. 补充缺失的标点
            2. 必要时分句
            3. 修正明显的同音字错误

            不做：不去口癖（嗯、那个、就是说全部保留）、不重组语句、不扩写、不总结。

            直接输出修正后的文本，不要加任何解释、前缀或引号。
            """
        case .light:
            return """
            你是中文语音转文字的后处理助手。需要：
            1. 修正同音字错误（如"以经"→"已经"）
            2. 补充或修正标点符号
            3. 修正中英文混输时的拼写
            4. 数字和日期按中文习惯表达
            5. 去除口头禅和语气词（嗯、啊、那个、就是说）
            6. 保持原意，不要改写、扩写或总结

            直接输出修正后的文本，不要加任何解释、前缀或引号。
            """
        case .structured:
            return """
            你是中文语音整理助手。用户口述内容可能逻辑跳跃、有重复、有口头禅。需要：
            1. 修正同音字和标点
            2. 去除口头禅、重复、无意义过渡词
            3. 理清逻辑顺序，让表达更流畅
            4. 多个要点时用清晰的分段或分点（带数字 / 字母编号）表达
            5. 保持原意和原有语气，不过度改写或添加原文没有的内容
            6. 原文很短或已清晰则只做轻度修正

            直接输出整理后的文本，不要加任何解释、前缀或引号。
            """
        case .formal:
            return """
            你是工作邮件 / 正式沟通助手。目标产出可直接发出的正式文本：
            1. 完成轻度润色的所有动作（去口癖、修标点、纠错）
            2. 措辞专业化：口语词替换为书面词（"我觉得"→"我认为"、"搞"→"完成"）
            3. 邮件场景自动识别：上下文像邮件则补合理问候 / 落款
            4. 不引入空泛客套（"如有疑问请联系"这种无信息量的句子不要写）
            5. 保持原意，不杜撰；信息缺失时留空让用户填，而非编造

            直接输出整理后的文本，不要加任何解释、前缀或引号。
            """
        }
    }

    /// 是否走「即时上屏 + 后台润色 + ⌘V 替换」的 UX；否则走「等润色完再上屏」
    /// 轻量级风格（raw / light）即时上屏体感更快，重型（structured / formal）输出差异大需等待
    var isImmediate: Bool {
        switch self {
        case .raw, .light: return true
        case .structured, .formal: return false
        }
    }
}

/// 风格设置存储 — master 开关 + 默认风格 + 启用的风格集合
@Observable
final class OutputStyleSettings {
    var masterEnabled: Bool = true {
        didSet { save() }
    }
    var defaultStyle: OutputStyle = .light {
        didSet { save() }
    }
    var enabledStyles: Set<OutputStyle> = Set(OutputStyle.allCases) {
        didSet { save() }
    }

    init() { load() }

    /// 双击 Fn 在启用的风格中循环；返回切换后的风格
    @discardableResult
    func cycle() -> OutputStyle {
        let ordered = OutputStyle.allCases.filter { enabledStyles.contains($0) }
        guard !ordered.isEmpty else { return defaultStyle }
        if let idx = ordered.firstIndex(of: defaultStyle), idx + 1 < ordered.count {
            defaultStyle = ordered[idx + 1]
        } else {
            defaultStyle = ordered.first!
        }
        return defaultStyle
    }

    /// 启停某个风格；至少保留 1 个启用；禁用了当前默认时切换到下一个启用
    func setEnabled(_ style: OutputStyle, enabled: Bool) {
        if enabled {
            enabledStyles.insert(style)
        } else {
            guard enabledStyles.count > 1 else { return }
            enabledStyles.remove(style)
            if defaultStyle == style {
                defaultStyle = OutputStyle.allCases.first { enabledStyles.contains($0) } ?? .light
            }
        }
    }

    func setDefault(_ style: OutputStyle) {
        guard enabledStyles.contains(style) else { return }
        defaultStyle = style
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(masterEnabled, forKey: "outputStyle_master")
        d.set(defaultStyle.rawValue, forKey: "outputStyle_default")
        d.set(enabledStyles.map(\.rawValue), forKey: "outputStyle_enabled")
    }

    private func load() {
        let d = UserDefaults.standard
        if d.object(forKey: "outputStyle_master") != nil {
            masterEnabled = d.bool(forKey: "outputStyle_master")
        }
        if let raw = d.string(forKey: "outputStyle_default"),
           let style = OutputStyle(rawValue: raw) {
            defaultStyle = style
        }
        if let arr = d.stringArray(forKey: "outputStyle_enabled") {
            let parsed = Set(arr.compactMap { OutputStyle(rawValue: $0) })
            if !parsed.isEmpty { enabledStyles = parsed }
        }
        // 旧版兼容：从 polishMode_legacy 迁移（如果有）
        if let legacy = d.string(forKey: "polishMode_legacy"),
           d.object(forKey: "outputStyle_default") == nil {
            defaultStyle = legacy == "structured" ? .structured : .light
        }
    }
}
