import AppKit
import Foundation

/// 语音引擎 — 协调录音→实时识别→润色→注入的完整流程
@MainActor
@Observable
class VoiceEngine {
    private let recorder = AudioRecorder()
    private let recognizer = SpeechRecognizer()
    private let hotkeyManager = HotkeyManager()
    private let polishService = PolishService()

    private(set) var appState: AppState

    private var recordingStartTime: Date?
    private var overlayWindow: OverlayWindow?
    private var rotationTimer: Timer?
    private var polishTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?

    /// SFSpeech 单次会话上限约 60s，55s 触发轮换留余量
    private let sessionRotationInterval: TimeInterval = 55

    private func log(_ msg: String) {
        VJLog.log(msg, prefix: "Engine")
    }

    init(appState: AppState) {
        self.appState = appState
        hotkeyManager.hotkey = appState.hotkey
        recognizer.setLanguage(appState.recognitionLanguage.rawValue)
        log("初始化，快捷键: \(appState.hotkey.displayName)，语言: \(appState.recognitionLanguage.displayName)")
        setupHotkey()

        // 监听快捷键变更
        NotificationCenter.default.addObserver(
            forName: .hotkeyChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let combo = notification.object as? HotkeyCombo {
                Task { @MainActor in
                    self?.updateHotkey(combo)
                }
            }
        }

        // 监听翻译快捷键变更
        NotificationCenter.default.addObserver(
            forName: .translateHotkeyChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let combo = notification.object as? HotkeyCombo {
                Task { @MainActor in
                    self?.hotkeyManager.translateHotkey = combo
                    self?.log("🌐 翻译快捷键切换: \(combo.displayName)")
                }
            }
        }

        // 监听"重复粘贴上次结果"快捷键变更
        NotificationCenter.default.addObserver(
            forName: .repeatLastHotkeyChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let combo = notification.object as? HotkeyCombo {
                Task { @MainActor in
                    self?.hotkeyManager.repeatLastHotkey = combo
                    self?.log("📋 重复粘贴快捷键切换: \(combo.displayName)")
                }
            }
        }

        // 监听暂停状态变更 — 同步到 HotkeyManager
        // 同时若处于"录音中切换到暂停"，立即取消已在跑的流程
        hotkeyManager.isPaused = appState.isPaused
        NotificationCenter.default.addObserver(
            forName: .pauseStateChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let paused = notification.object as? Bool {
                Task { @MainActor in
                    guard let self else { return }
                    self.hotkeyManager.isPaused = paused
                    self.log(paused ? "⏸️ 已暂停（菜单栏切换）" : "▶️ 已恢复")
                    if paused {
                        self.cancelInFlight()
                    }
                    self.appState.statusMessage = paused
                        ? "已暂停 — 菜单栏点开切回 启用"
                        : "按住 \(self.appState.hotkey.displayName) 开始说话"
                }
            }
        }

        // 监听语言变更
        NotificationCenter.default.addObserver(
            forName: .recognitionLanguageChanged, object: nil, queue: .main
        ) { [weak self] notification in
            if let lang = notification.object as? RecognitionLanguage {
                Task { @MainActor in
                    self?.recognizer.setLanguage(lang.rawValue)
                    self?.log("🌐 语言切换: \(lang.displayName)")
                }
            }
        }
    }

    /// 设置全局快捷键回调
    private func setupHotkey() {
        hotkeyManager.onRecordStart = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }
        hotkeyManager.onRecordStop = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndProcess()
            }
        }
        hotkeyManager.onDoubleTap = { [weak self] in
            Task { @MainActor in
                self?.togglePolishMode()
            }
        }
        hotkeyManager.onTranslate = { [weak self] in
            Task { @MainActor in
                self?.translateSelectedText()
            }
        }
        hotkeyManager.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelInFlight()
            }
        }
        hotkeyManager.onRepeatLast = { [weak self] in
            Task { @MainActor in
                self?.repeatLastInjection()
            }
        }
        hotkeyManager.isFlowActive = { [weak self] in
            guard let self else { return false }
            // CGEventTap callback 运行在主 RunLoop 上（VoiceEngine 是 @MainActor 注册的），
            // 但编译器看不到这层运行时保证，需要显式 assumeIsolated。
            return MainActor.assumeIsolated {
                self.appState.isRecording || self.appState.isProcessing || self.appState.isTranslating
            }
        }
        hotkeyManager.onTranslateMidRecording = { [weak self] marked in
            Task { @MainActor in
                self?.handleTranslateMarkChanged(marked)
            }
        }
        // 初始注入翻译触发键
        refreshTranslationTrigger()
        hotkeyManager.startListening()
    }

    /// 让 HotkeyManager 知道当前的翻译触发键（设置变化时由 UI 触发刷新）
    func refreshTranslationTrigger() {
        if appState.translation.isActiveForRecording {
            hotkeyManager.translationTriggerMask = appState.translation.triggerMask
        } else {
            hotkeyManager.translationTriggerMask = nil
        }
    }

    private func handleTranslateMarkChanged(_ marked: Bool) {
        log("🌐 本次录音翻译标记 = \(marked)")
        if overlayWindow == nil { overlayWindow = OverlayWindow() }
        overlayWindow?.showTranslationBadge(marked)
    }

    /// 更新快捷键绑定
    func updateHotkey(_ combo: HotkeyCombo) {
        hotkeyManager.rebind(to: combo)
    }

    /// 设置窗口打开时暂停翻译快捷键拦截，关闭时恢复
    func suppressTranslateHotkey(_ suppress: Bool) {
        hotkeyManager.suppressTranslateHotkey = suppress
        log(suppress ? "⏸️ 翻译快捷键拦截已暂停（设置窗口）" : "▶️ 翻译快捷键拦截已恢复")
    }

    /// 双击 Fn 在启用的风格之间循环切换默认风格
    func togglePolishMode() {
        let next = appState.outputStyle.cycle()
        log("🔄 切换风格 → \(next.title)")
        appState.statusMessage = "切换到「\(next.title)」"

        // 显示浮窗短暂提示
        if overlayWindow == nil { overlayWindow = OverlayWindow() }
        overlayWindow?.updateText("切换到「\(next.title)」")
        overlayWindow?.show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.hideOverlay()
        }
    }

    // MARK: - 翻译

    func translateSelectedText() {
        guard !appState.isRecording && !appState.isTranslating else {
            log("⚠️ 正在录音或翻译中，忽略")
            return
        }

        log("🌐 开始翻译选中文本")
        appState.isTranslating = true

        // 显示浮窗
        if overlayWindow == nil { overlayWindow = OverlayWindow() }
        overlayWindow?.showTranslating()
        overlayWindow?.show()

        let translateSnapshot = appState.translateSettings.snapshot
        let targetLang = appState.translateTargetLang.promptDescription
        let polishService = self.polishService

        translateTask = Task {
            // 抓取选中文本
            guard let selectedText = await TextInjector.grabSelectedText(),
                  !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                self.log("⚠️ 未获取到选中文本")
                self.overlayWindow?.updateText("未选中文本")
                self.appState.isTranslating = false
                self.translateTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.hideOverlay()
                }
                return
            }

            self.log("📝 选中文本: \(selectedText)")

            do {
                let translated = try await polishService.translate(
                    text: selectedText, settings: translateSnapshot, targetLang: targetLang
                )
                self.log("✅ 翻译结果: \(translated)")
                self.appState.translatedText = translated

                // 复制到剪贴板
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(translated, forType: .string)

                // 显示结果
                self.overlayWindow?.showTranslated(translated)
                self.appState.isTranslating = false
                self.translateTask = nil

                // 5秒后自动隐藏
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                    guard let self else { return }
                    if !self.appState.isTranslating && !self.appState.isRecording {
                        self.hideOverlay()
                    }
                }
            } catch {
                self.log("❌ 翻译失败: \(error)")
                self.overlayWindow?.updateText("翻译失败: \(error.localizedDescription)")
                self.appState.isTranslating = false
                self.translateTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                    self?.hideOverlay()
                }
            }
        }
    }

    // MARK: - 录音控制（流式实时识别）

    func startRecording() {
        guard !appState.isRecording else {
            log("⚠️ 已在录音中，忽略重复调用")
            return
        }

        log("▶️ 开始录音（流式模式）")

        // 重置状态
        appState.rawTranscription = ""
        appState.polishedText = ""
        appState.liveText = ""
        appState.errorMessage = nil
        // 重置翻译标记 + 触发键（设置可能已变更）
        hotkeyManager.translateMarked = false
        refreshTranslationTrigger()

        // 设置流式识别的音频回调
        recorder.onAudioBuffer = { [weak self] buffer in
            self?.recognizer.appendBuffer(buffer)
        }

        // 启动流式识别（注入词典作为 contextualStrings）
        recognizer.startStreaming(
            contextualStrings: appState.vocab.activeTerms,
            onPartialResult: { [weak self] text in
                DispatchQueue.main.async {
                    self?.appState.liveText = text
                    self?.overlayWindow?.updateText(text)
                }
            },
            onFinalResult: { [weak self] text in
                DispatchQueue.main.async {
                    self?.appState.liveText = text
                    self?.appState.rawTranscription = text
                    self?.overlayWindow?.updateText(text)
                    self?.log("✅ 最终识别结果: \(text)")
                }
            },
            onError: { [weak self] error in
                DispatchQueue.main.async {
                    self?.log("❌ 流式识别错误: \(error)")
                    // No speech detected 不算错误，用户可能还没开始说
                    if (error as NSError).code != 1110 {
                        self?.appState.errorMessage = "识别错误: \(error.localizedDescription)"
                    }
                }
            }
        )

        // 启动录音
        do {
            try recorder.startRecording()
            recordingStartTime = Date()
            appState.isRecording = true
            appState.statusMessage = "正在录音…"

            // 显示浮窗
            showOverlay()

            // 启动会话轮换 timer：每 55s 切一次新 ASR session 绕开 60s 限制
            rotationTimer?.invalidate()
            rotationTimer = Timer.scheduledTimer(withTimeInterval: sessionRotationInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.appState.isRecording else { return }
                    self.log("🔄 ASR 会话轮换（避免 60s 上限）")
                    self.recognizer.rotate()
                }
            }

            log("✅ 流式录音已启动")
        } catch {
            log("❌ 录音启动失败: \(error)")
            appState.errorMessage = "录音启动失败: \(error.localizedDescription)"
            recognizer.cancel()
        }
    }

    func stopRecordingAndProcess() {
        guard appState.isRecording else { return }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        log("⏹️ 停止录音，时长: \(String(format: "%.1f", duration))秒")

        // 停止录音 + 轮换 timer
        rotationTimer?.invalidate()
        rotationTimer = nil
        let _ = recorder.stopRecording()
        recorder.onAudioBuffer = nil

        // 告知识别器没有更多音频
        recognizer.finishStreaming()

        appState.isRecording = false

        // 等一小段时间让最终结果回来，然后处理润色
        let rawText = appState.liveText
        log("📝 当前文本: \(rawText)")

        guard !rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("⚠️ 无有效文本")
            appState.statusMessage = "未检测到语音"
            hideOverlay()
            return
        }

        appState.rawTranscription = rawText
        let polishSnapshot = appState.polishSettings.snapshot
        let translateSnapshot = appState.translateSettings.snapshot
        let style = appState.outputStyle.defaultStyle
        let masterEnabled = appState.outputStyle.masterEnabled
        let useStreamingMode = masterEnabled && polishSnapshot.engine != .none && !style.isImmediate

        let vocabTerms = appState.vocab.activeTerms
        let workingLangs = appState.translation.workingLanguages.map(\.promptName)

        // 口述翻译分流：若用户在录音中标记了翻译且配置了目标语言 → 走翻译管线
        let shouldTranslate = hotkeyManager.translateMarked &&
            appState.translation.isActiveForRecording &&
            translateSnapshot.engine != .none

        if shouldTranslate, let targetLang = appState.translation.targetLanguage {
            handleDictationTranslation(
                rawText: rawText,
                duration: duration,
                targetLang: targetLang,
                translateSnapshot: translateSnapshot,
                workingLanguages: workingLangs
            )
            return
        }

        if useStreamingMode {
            // 润色模式：流式显示 + 完成后上屏
            log("✨ 润色模式 — 流式 AI 整理")
            appState.isProcessing = true
            overlayWindow?.showProcessing()
            overlayWindow?.updateProcessingText("整理中…")

            let polishService = self.polishService
            polishTask = Task { [weak self] in
                guard let self else { return }
                self.log("🔄 流式润色 [\(style.title)] (\(polishSnapshot.engine.rawValue))")
                let finalText: String
                do {
                    finalText = try await polishService.polishStream(
                        text: rawText,
                        settings: polishSnapshot,
                        style: style,
                        vocabTerms: vocabTerms
                    ) { [weak self] accumulated in
                        Task { @MainActor in
                            self?.overlayWindow?.updateProcessingText(accumulated)
                        }
                    }
                    self.log("✅ 润色结果: \(finalText)")
                } catch {
                    self.log("⚠️ 润色失败，使用原文: \(error)")
                    finalText = rawText
                }

                if Task.isCancelled { return }

                await MainActor.run {
                    self.polishTask = nil
                    self.appState.polishedText = finalText
                    self.appState.vocab.recordHits(in: finalText)
                    self.hideOverlay()

                    switch self.appState.inputMode {
                    case .universal:
                        TextInjector.inject(finalText)
                    case .journal:
                        self.openJournalWithText(finalText)
                    }

                    self.addHistory(rawText: rawText, polishedText: finalText, duration: duration)
                    self.appState.isProcessing = false
                    self.appState.statusMessage = "按住 \(self.appState.hotkey.displayName) 开始说话"
                }
            }
        } else {
            // 即时模式：松开即上屏
            hideOverlay()
            log("⚡ 即时上屏: \(rawText)")

            switch appState.inputMode {
            case .universal:
                TextInjector.inject(rawText)
            case .journal:
                openJournalWithText(rawText)
            }

            addHistory(rawText: rawText, polishedText: rawText, duration: duration)

            // 后台润色 → 润色完成后自动替换已注入的原文
            if masterEnabled && polishSnapshot.engine != .none {
                appState.isProcessing = true
                let polishService = self.polishService
                polishTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let polished = try await polishService.polish(text: rawText, settings: polishSnapshot, style: style, vocabTerms: vocabTerms)
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.polishTask = nil
                            self.appState.polishedText = polished
                            self.appState.vocab.recordHits(in: polished)
                            self.appState.isProcessing = false
                            self.appState.statusMessage = "按住 \(self.appState.hotkey.displayName) 开始说话"

                            // AI 润色完成后，写入剪贴板 + 浮窗提示
                            if polished != rawText {
                                self.log("✨ 润色完成，已写入剪贴板")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(polished, forType: .string)
                                self.showOverlay()
                                self.overlayWindow?.updateText("✨ 已润色 · ⌘V 可替换")
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                                    guard let self, !self.appState.isRecording else { return }
                                    self.hideOverlay()
                                }
                            }
                        }
                    } catch {
                        if Task.isCancelled { return }
                        await MainActor.run {
                            self.polishTask = nil
                            self.appState.polishedText = rawText
                            self.appState.isProcessing = false
                        }
                    }
                }
            } else {
                appState.polishedText = rawText
                appState.statusMessage = "按住 \(appState.hotkey.displayName) 开始说话"
            }
        }
    }

    /// 口述翻译路径：转写 → translate(targetLang) → inject；失败 fallback 到 raw text
    private func handleDictationTranslation(
        rawText: String,
        duration: TimeInterval,
        targetLang: WorkingLanguage,
        translateSnapshot: PolishSettingsSnapshot,
        workingLanguages: [String]
    ) {
        log("🌐 走翻译管线 → \(targetLang.displayName)")
        appState.isProcessing = true
        appState.statusMessage = "翻译中…"
        showOverlay()
        overlayWindow?.showProcessing()
        overlayWindow?.updateProcessingText("翻译为 \(targetLang.displayName)…")

        let polishService = self.polishService
        polishTask = Task { [weak self] in
            guard let self else { return }
            let finalText: String
            do {
                finalText = try await polishService.translate(
                    text: rawText,
                    settings: translateSnapshot,
                    targetLang: targetLang.promptName,
                    workingLanguages: workingLanguages
                )
                self.log("✅ 翻译结果: \(finalText)")
            } catch {
                self.log("⚠️ 翻译失败 fallback 到原文: \(error)")
                finalText = rawText
            }
            if Task.isCancelled { return }
            await MainActor.run {
                self.polishTask = nil
                self.appState.polishedText = finalText
                self.hideOverlay()
                self.overlayWindow?.showTranslationBadge(false)
                self.hotkeyManager.translateMarked = false
                switch self.appState.inputMode {
                case .universal: TextInjector.inject(finalText)
                case .journal: self.openJournalWithText(finalText)
                }
                self.addHistory(rawText: rawText, polishedText: finalText, duration: duration)
                self.appState.isProcessing = false
                self.appState.statusMessage = "按住 \(self.appState.hotkey.displayName) 开始说话"
            }
        }
    }

    /// 重新粘贴上次注入文本 — 触发时直接 inject TextInjector.lastInjectedText
    /// 录音/翻译进行中不响应，避免与正在写入的流程互相打架
    func repeatLastInjection() {
        guard !appState.isRecording && !appState.isProcessing && !appState.isTranslating else {
            log("📋 重复粘贴被忽略（流程进行中）")
            return
        }
        let text = TextInjector.lastInjectedText
        guard !text.isEmpty else {
            log("📋 重复粘贴：无历史内容")
            appState.statusMessage = "暂无可重粘贴的内容"
            return
        }
        log("📋 重复粘贴上次结果（\(text.count) 字）")
        TextInjector.inject(text)
    }

    /// 全链路取消（Esc 触发）— 干净地中止任何正在进行的录音 / 识别 / 润色 / 翻译
    func cancelInFlight() {
        guard appState.isRecording || appState.isProcessing || appState.isTranslating else {
            return
        }
        log("🛑 Esc 取消全链路")

        // 1. 录音 + ASR
        rotationTimer?.invalidate()
        rotationTimer = nil
        if appState.isRecording {
            _ = recorder.stopRecording()
            recorder.onAudioBuffer = nil
        }
        recognizer.cancel()

        // 2. 异步任务
        polishTask?.cancel()
        polishTask = nil
        translateTask?.cancel()
        translateTask = nil

        // 3. UI / 状态
        hideOverlay()
        appState.isRecording = false
        appState.isProcessing = false
        appState.isTranslating = false
        appState.liveText = ""
        appState.statusMessage = "已取消 · 按住 \(appState.hotkey.displayName) 开始说话"
    }

    private func addHistory(rawText: String, polishedText: String, duration: TimeInterval) {
        let record = TranscriptionRecord(
            rawText: rawText, polishedText: polishedText,
            timestamp: Date(), duration: duration
        )
        appState.history.insert(record, at: 0)
        if appState.history.count > 50 {
            appState.history = Array(appState.history.prefix(50))
        }
        appState.stats.record(chars: polishedText.count, seconds: duration)
    }

    // MARK: - 浮窗

    private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }
        overlayWindow?.setStructured(!appState.outputStyle.defaultStyle.isImmediate)
        overlayWindow?.updateText("")
        overlayWindow?.show()
    }

    private func hideOverlay() {
        overlayWindow?.hide()
    }

    // MARK: - 日志联动

    private func openJournalWithText(_ text: String) {
        guard let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "babyjournal://new?text=\(encoded)") else { return }
        NSWorkspace.shared.open(url)
    }
}
