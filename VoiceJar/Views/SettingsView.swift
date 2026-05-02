import SwiftUI
import AVFoundation
import Speech

/// 设置窗口 — 现代化侧边栏布局
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab: SettingsTab = .home

    enum SettingsTab: String, CaseIterable {
        case home = "主页"
        case general = "通用"
        case style = "风格"
        case translate = "翻译"
        case ai = "AI 润色"
        case vocab = "词典"
        case about = "关于"

        var icon: String {
            switch self {
            case .home: return "house"
            case .general: return "gearshape"
            case .style: return "paintpalette"
            case .translate: return "globe"
            case .ai: return "sparkles"
            case .vocab: return "character.book.closed"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.icon)
                    .font(.system(size: 13))
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 140, ideal: 160, max: 180)
        } detail: {
            switch selectedTab {
            case .home:
                HomeSettingsView(appState: appState)
            case .general:
                GeneralSettingsView(appState: appState)
            case .style:
                StyleSettingsView(appState: appState)
            case .translate:
                TranslateSettingsView(appState: appState)
            case .ai:
                AISettingsView(appState: appState)
            case .vocab:
                VocabSettingsView(appState: appState)
            case .about:
                AboutSettingsView()
            }
        }
        .frame(width: 560, height: 580)
    }
}

// MARK: - 通用设置

struct GeneralSettingsView: View {
    @Bindable var appState: AppState
    @State private var diagnosticReport: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // 标题
                Text("通用")
                    .font(.system(size: 20, weight: .semibold))

                // 快捷键
                SettingsSection(title: "快捷键", description: "按住快捷键说话，松开自动识别并输入") {
                    HStack {
                        Text("按住说话")
                            .font(.system(size: 13))
                        Spacer()
                        HotkeyRecorderView(hotkey: $appState.hotkey) { combo in
                            NotificationCenter.default.post(name: .hotkeyChanged, object: combo)
                        }
                    }
                }

                // 识别语言
                SettingsSection(title: "识别语言", description: "选择语音识别的目标语言") {
                    Picker("", selection: Binding(
                        get: { appState.recognitionLanguage },
                        set: { newLang in
                            appState.recognitionLanguage = newLang
                            NotificationCenter.default.post(name: .recognitionLanguageChanged, object: newLang)
                        }
                    )) {
                        ForEach(RecognitionLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                // 输入模式
                SettingsSection(title: "输入模式", description: "通用模式将文本粘贴到光标位置；日志模式发送到 BabyJournal") {
                    Picker("", selection: $appState.inputMode) {
                        ForEach(InputMode.allCases, id: \.self) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // 权限
                SettingsSection(title: "权限", description: "VoiceBee 需要这些权限才能正常工作") {
                    PermissionRow(
                        name: "辅助功能",
                        description: "监听全局快捷键",
                        icon: "hand.raised",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
                    )
                    Divider()
                    PermissionRow(
                        name: "麦克风",
                        description: "录制语音",
                        icon: "mic",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    )
                    Divider()
                    PermissionRow(
                        name: "语音识别",
                        description: "语音转文字",
                        icon: "waveform",
                        url: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                    )
                }

                // 诊断工具
                SettingsSection(title: "诊断", description: "检测所有权限和系统功能是否正常") {
                    VStack(alignment: .leading, spacing: 8) {
                        Button("运行诊断") {
                            diagnosticReport = PermissionDiagnostics.runDiagnostics()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)

                        if let report = diagnosticReport {
                            Text(report)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

// MARK: - 权限诊断工具

enum PermissionDiagnostics {
    static func runDiagnostics() -> String {
        var lines: [String] = ["VoiceBee 诊断报告", ""]

        // 1. 辅助功能
        let axTrusted = AXIsProcessTrusted()
        lines.append("辅助功能: \(axTrusted ? "✅ 已授权" : "❌ 未授权")")

        // 2. 焦点元素检测
        if axTrusted {
            let sys = AXUIElementCreateSystemWide()
            var focused: AnyObject?
            let r = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focused)
            lines.append("焦点元素: \(r == .success ? "✅ 可获取" : "❌ 获取失败 (\(r.rawValue))")")

            if r == .success, let el = focused {
                var role: AnyObject?
                AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role)
                lines.append("元素角色: \(role as? String ?? "unknown")")
            }
        }

        // 3. CGEvent（文本注入能力）
        let source = CGEventSource(stateID: .hidSystemState)
        lines.append("CGEventSource: \(source != nil ? "✅" : "❌ nil")")
        let testEvent = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        lines.append("CGEvent 创建: \(testEvent != nil ? "✅" : "❌ nil")")

        // 4. 麦克风
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        lines.append("麦克风: \(micStatus == .authorized ? "✅ 已授权" : "❌ 状态 \(micStatus.rawValue)")")

        // 5. 语音识别
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        lines.append("语音识别: \(speechStatus == .authorized ? "✅ 已授权" : "❌ 状态 \(speechStatus.rawValue)")")

        // 6. 识别器可用性
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans"))
        lines.append("识别器可用: \(recognizer?.isAvailable == true ? "✅" : "❌")")

        return lines.joined(separator: "\n")
    }
}

// MARK: - 翻译设置

struct TranslateSettingsView: View {
    @Bindable var appState: AppState

    /// 翻译可用的引擎（排除"不润色"选项）
    private var availableEngines: [PolishEngine] {
        PolishEngine.allCases.filter { $0 != .none }
    }

    private var conflictingTriggers: Set<TranslationTrigger> {
        TranslationSettings.conflictingTriggers(mainModifiers: appState.hotkey.modifiers)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("翻译")
                    .font(.system(size: 20, weight: .semibold))

                // 工作语言（多选 chip）
                SettingsSection(
                    title: "工作语言",
                    description: "勾选你日常用到的语言（多选）。这组语言会作为前提注入 LLM 的 system prompt，影响润色与翻译对专名 / 语气 / 行文习惯的判断。"
                ) {
                    LanguageChipFlow(
                        selected: Binding(
                            get: { appState.translation.workingLanguages },
                            set: { appState.translation.workingLanguages = $0 }
                        )
                    )
                }

                // 口述翻译目标语言
                SettingsSection(
                    title: "口述翻译目标语言",
                    description: "选某语言后，录音中按一下触发键即可把转写翻译成此语言再插入光标。选「不启用」则触发键无任何效果。"
                ) {
                    // 显式标注为 Optional<WorkingLanguage> 让 binding 与 tag 类型一致
                    Picker("", selection: Binding<WorkingLanguage?>(
                        get: { appState.translation.targetLanguage },
                        set: { appState.translation.targetLanguage = $0 }
                    )) {
                        Text("不启用").tag(WorkingLanguage?.none)
                        Divider()
                        ForEach(WorkingLanguage.allCases) { lang in
                            Text(lang.displayName).tag(WorkingLanguage?.some(lang))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                }

                // 触发键（带冲突检测）
                SettingsSection(
                    title: "翻译触发键",
                    description: "录音中单击此键标记本次走翻译管线；再按一下取消。事件不消费，会透传给前台 App。"
                ) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(TranslationTrigger.allCases) { trigger in
                            TriggerRow(
                                trigger: trigger,
                                isSelected: appState.translation.trigger == trigger,
                                isConflict: conflictingTriggers.contains(trigger),
                                showShiftWarning: trigger == .shift,
                                onSelect: { appState.translation.trigger = trigger }
                            )
                        }
                    }
                }

                // 使用方法
                SettingsSection(title: "使用方法", description: "") {
                    VStack(alignment: .leading, spacing: 8) {
                        UsageStep(num: 1, text: "在任意 App 输入框聚焦光标")
                        UsageStep(num: 2, text: "按住录音快捷键 (\(appState.hotkey.displayName)) 开始说话")
                        UsageStep(num: 3, text: "录音中**任意时刻**单击「\(appState.translation.trigger.displayName)」一下，浮窗顶端会出现「● 正在翻译」蓝色药丸")
                        UsageStep(num: 4, text: "松开录音键停止")
                        UsageStep(num: 5, text: "系统把转写交给 LLM 翻译成目标语言并插入到光标")
                    }
                }

                // 安全兜底
                VStack(alignment: .leading, spacing: 6) {
                    Text("安全兜底")
                        .font(.system(size: 13, weight: .semibold))
                    Text("• 翻译目标语言选「不启用」时触发键完全无效。\n• 翻译过程中 LLM 调用失败 → 自动回退到原始转写直接插入，不会丢字。\n• 录音中已标记翻译可以再单击触发键取消标记。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                Divider().padding(.vertical, 4)

                Text("选词翻译")
                    .font(.system(size: 16, weight: .semibold))

                Text("选中已有文字 → 按快捷键 → 翻译结果复制到剪贴板。与口述翻译并行使用。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                // 选词翻译快捷键
                SettingsSection(title: "选词翻译快捷键", description: "") {
                    HStack {
                        Text("快捷键")
                            .font(.system(size: 13))
                        Spacer()
                        HotkeyRecorderView(hotkey: $appState.translateHotkey) { combo in
                            NotificationCenter.default.post(name: .translateHotkeyChanged, object: combo)
                        }
                    }
                }

                // 选词翻译目标语言（旧的 enum）
                SettingsSection(title: "选词翻译目标语言", description: "") {
                    Picker("", selection: Binding(
                        get: { appState.translateTargetLang },
                        set: { appState.translateTargetLang = $0 }
                    )) {
                        ForEach(TranslateTargetLanguage.allCases, id: \.self) { lang in
                            Text(lang.displayName).tag(lang)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()
                }

                // 翻译引擎选择
                SettingsSection(title: "翻译引擎", description: "选择用于翻译的 AI 服务（独立于润色引擎，口述翻译与选词翻译共享）") {
                    VStack(spacing: 8) {
                        ForEach(availableEngines, id: \.self) { engine in
                            EngineOptionRow(
                                engine: engine,
                                isSelected: appState.translateSettings.engine == engine
                            ) {
                                appState.translateSettings.switchEngine(to: engine)
                            }
                        }
                    }
                }

                // 引擎配置
                if appState.translateSettings.engine != .none {
                    SettingsSection(title: "翻译引擎配置", description: translateEngineDescription) {
                        VStack(spacing: 12) {
                            SettingsTextField(
                                label: "模型",
                                placeholder: appState.translateSettings.engine.defaultModel,
                                text: Binding(
                                    get: {
                                        appState.translateSettings.model.isEmpty
                                            ? appState.translateSettings.engine.defaultModel
                                            : appState.translateSettings.model
                                    },
                                    set: { appState.translateSettings.model = $0 }
                                ),
                                isMonospaced: true
                            )

                            if appState.translateSettings.engine.needsAPIKey {
                                SettingsSecureField(
                                    label: "API Key",
                                    placeholder: "sk-...",
                                    text: Binding(
                                        get: { appState.translateSettings.apiKey },
                                        set: { appState.translateSettings.apiKey = $0 }
                                    )
                                )
                            }

                            if appState.translateSettings.engine != .ollama && appState.translateSettings.engine != .ollamaCloud {
                                SettingsTextField(
                                    label: "API 地址",
                                    placeholder: "留空使用默认地址",
                                    text: Binding(
                                        get: { appState.translateSettings.baseURL },
                                        set: { appState.translateSettings.baseURL = $0 }
                                    ),
                                    isMonospaced: true
                                )
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private var translateEngineDescription: String {
        switch appState.translateSettings.engine {
        case .ollama: return "确保 Ollama 已在本机运行（默认端口 11434）"
        case .ollamaCloud: return "使用 Ollama 云端模型，通过本地 Ollama 代理访问"
        case .claude: return "需要 Anthropic API Key，从 console.anthropic.com 获取"
        case .deepseek: return "需要 DeepSeek API Key，从 platform.deepseek.com 获取"
        case .gemini: return "需要 Google AI API Key，从 aistudio.google.com 获取"
        case .openaiCompatible: return "支持任何 OpenAI 兼容的 API 服务"
        case .none: return ""
        }
    }
}

// MARK: - AI 润色设置

struct AISettingsView: View {
    @Bindable var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("AI 润色")
                    .font(.system(size: 20, weight: .semibold))

                Text("语音识别后，AI 会自动修正同音字、补标点、去口头禅、优化中英混输。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // 引擎选择
                SettingsSection(title: "润色引擎", description: "选择 AI 服务提供商，Ollama 可本地运行无需联网") {
                    VStack(spacing: 8) {
                        ForEach(PolishEngine.allCases, id: \.self) { engine in
                            EngineOptionRow(
                                engine: engine,
                                isSelected: appState.polishSettings.engine == engine
                            ) {
                                appState.polishSettings.switchEngine(to: engine)
                            }
                        }
                    }
                }

                // 引擎配置
                if appState.polishSettings.engine != .none {
                    SettingsSection(title: "配置", description: engineConfigDescription) {
                        VStack(spacing: 12) {
                            SettingsTextField(
                                label: "模型",
                                placeholder: appState.polishSettings.engine.defaultModel,
                                text: Binding(
                                    get: {
                                        appState.polishSettings.model.isEmpty
                                            ? appState.polishSettings.engine.defaultModel
                                            : appState.polishSettings.model
                                    },
                                    set: { appState.polishSettings.model = $0 }
                                ),
                                isMonospaced: true
                            )

                            if appState.polishSettings.engine.needsAPIKey {
                                SettingsSecureField(
                                    label: "API Key",
                                    placeholder: "sk-...",
                                    text: Binding(
                                        get: { appState.polishSettings.apiKey },
                                        set: { appState.polishSettings.apiKey = $0 }
                                    )
                                )
                            }

                            if appState.polishSettings.engine != .ollama && appState.polishSettings.engine != .ollamaCloud {
                                SettingsTextField(
                                    label: "API 地址",
                                    placeholder: "留空使用默认地址",
                                    text: Binding(
                                        get: { appState.polishSettings.baseURL },
                                        set: { appState.polishSettings.baseURL = $0 }
                                    ),
                                    isMonospaced: true
                                )
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }

    private var engineConfigDescription: String {
        switch appState.polishSettings.engine {
        case .ollama: return "确保 Ollama 已在本机运行（默认端口 11434）"
        case .ollamaCloud: return "使用 Ollama 云端模型，通过本地 Ollama 代理访问"
        case .claude: return "需要 Anthropic API Key，从 console.anthropic.com 获取"
        case .deepseek: return "需要 DeepSeek API Key，从 platform.deepseek.com 获取"
        case .gemini: return "需要 Google AI API Key，从 aistudio.google.com 获取"
        case .openaiCompatible: return "支持任何 OpenAI 兼容的 API 服务"
        case .none: return ""
        }
    }
}

// MARK: - 关于

struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "mic.badge.waveform")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("VoiceBee")
                .font(.system(size: 24, weight: .bold))

            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0")")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            Text("按住说话，松开输入")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)

            if UpdaterManager.isConfigured {
                Button("检查更新") {
                    UpdaterManager.shared.checkForUpdates()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .padding(.top, 4)
            } else {
                Text("自动更新未配置（开发版）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }

            VStack(spacing: 4) {
                Text("中文语音输入，快人一步")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                Text("© 2026 Clearsky")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 通用组件

/// 设置区块
struct SettingsSection<Content: View>: View {
    let title: String
    var description: String = ""
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))

            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                content()
            }
            .padding(12)
            .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// 引擎选项行
struct EngineOptionRow: View {
    let engine: PolishEngine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(.primary)
                    if engine != .none {
                        Text(engineSubtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                if engine == .ollama {
                    Text("本地")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.15), in: Capsule())
                        .foregroundStyle(.green)
                }
                if engine == .ollamaCloud {
                    Text("云端")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var engineSubtitle: String {
        switch engine {
        case .none: return ""
        case .ollama: return "离线运行，隐私安全"
        case .ollamaCloud: return "Ollama 云端模型，无需本地显卡"
        case .claude: return "Anthropic，高质量"
        case .deepseek: return "性价比高"
        case .gemini: return "Google，免费额度大"
        case .openaiCompatible: return "自定义 API 端点"
        }
    }
}

/// 文本输入行
struct SettingsTextField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    var isMonospaced: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(isMonospaced ? .system(size: 12, design: .monospaced) : .system(size: 12))
        }
    }
}

/// 密码输入行
struct SettingsSecureField: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @State private var isVisible = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if isVisible {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                } else {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }
                Button {
                    isVisible.toggle()
                } label: {
                    Image(systemName: isVisible ? "eye.slash" : "eye")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 权限行
struct PermissionRow: View {
    let name: String
    let description: String
    let icon: String
    let url: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("打开设置") {
                if let settingsURL = URL(string: url) {
                    NSWorkspace.shared.open(settingsURL)
                }
            }
            .font(.system(size: 11))
            .buttonStyle(.link)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 翻译辅助组件

/// 工作语言多选 chip 流式布局
private struct LanguageChipFlow: View {
    @Binding var selected: Set<WorkingLanguage>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(WorkingLanguage.allCases) { lang in
                let isOn = selected.contains(lang)
                Button {
                    if isOn { selected.remove(lang) } else { selected.insert(lang) }
                } label: {
                    Text(lang.displayName)
                        .font(.system(size: 12, weight: isOn ? .medium : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(isOn ? Color.blue : Color.secondary.opacity(0.12), in: Capsule())
                        .foregroundStyle(isOn ? .white : Color.primary.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 翻译触发键单行（含冲突灰显 + IME 警告）
private struct TriggerRow: View {
    let trigger: TranslationTrigger
    let isSelected: Bool
    let isConflict: Bool
    let showShiftWarning: Bool
    let onSelect: () -> Void

    private var disabled: Bool { isConflict }

    var body: some View {
        Button(action: { if !disabled { onSelect() } }) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "circle.fill" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.blue : .secondary.opacity(0.5))
                Text(trigger.symbol)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .frame(width: 24)
                    .foregroundStyle(disabled ? .tertiary : .primary)
                Text(trigger.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(disabled ? .tertiary : .primary)
                Spacer()
                if isConflict {
                    Text("与录音键冲突")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                } else if showShiftWarning {
                    Text("⚠ 可能与输入法切换冲突")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange.opacity(0.8))
                }
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

/// 数字步骤行（蓝圆 + 文本）
private struct UsageStep: View {
    let num: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(num)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.blue, in: Circle())
            Text(text)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// 流式横向布局（已在 VocabSettingsView 用过；这里复制一份作私有以避免文件间依赖）
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
