import AppKit
import Foundation

/// 语音引擎 — 协调录音→实时识别→润色→注入的完整流程
@MainActor
@Observable
class VoiceEngine {
    /// ASR provider — 60s rotation 等实现细节隐藏在 provider 内部(D3),
    /// provider 自管麦克风(D1 revised),VoiceEngine 是协调者不持 mic/timer.
    /// Phase 2F:var,根据 appState.asrEngine 实例化 + 切换时 swap.
    private var asrProvider: any ASRProvider

    private let hotkeyManager = HotkeyManager()
    private let polishService = PolishService()

    private(set) var appState: AppState

    private var recordingStartTime: Date?
    private var overlayWindow: OverlayWindow?
    private var streamingTask: Task<Void, Never>?
    private var polishTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?

    private func log(_ msg: String) {
        VJLog.log(msg, prefix: "Engine")
    }

    init(appState: AppState) {
        self.appState = appState
        // Phase 2F:根据 appState.asrEngine 实例化(F3 — VoiceEngine init 内调度 prepare)
        // makeProvider 是实例方法,继承 @MainActor 从 class
        self.asrProvider = Self.makeProvider(for: appState.asrEngine)
        hotkeyManager.hotkey = appState.hotkey
        log("初始化，快捷键: \(appState.hotkey.displayName)，语言: \(appState.recognitionLanguage.displayName)，ASR: \(type(of: asrProvider).id.rawValue)")
        setupHotkey()

        // 监听快捷键变更
        NotificationCenter.default.addObserver(
            forName: .hotkeyChanged, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
            if let combo = notification.object as? HotkeyCombo {
                Task { @MainActor in
                    self?.updateHotkey(combo)
                }
            }
        }

        // 监听翻译快捷键变更
        NotificationCenter.default.addObserver(
            forName: .translateHotkeyChanged, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
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
        ) { @Sendable [weak self] notification in
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
        ) { @Sendable [weak self] notification in
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

        // 监听语言变更 — ASRProvider 协议下 language 是每次 startStreaming 传参,
        // 此处仅 log;下次按 hotkey 录音时自动用 appState.recognitionLanguage.rawValue
        NotificationCenter.default.addObserver(
            forName: .recognitionLanguageChanged, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
            if let lang = notification.object as? RecognitionLanguage {
                Task { @MainActor in
                    self?.log("🌐 语言切换: \(lang.displayName)(下次录音生效)")
                }
            }
        }

        // Phase 2F: 监听 ASR 引擎切换
        NotificationCenter.default.addObserver(
            forName: .asrEngineChanged, object: nil, queue: .main
        ) { @Sendable [weak self] notification in
            if let engine = notification.object as? ASREngine {
                Task { @MainActor in
                    self?.swapProvider(to: engine)
                }
            }
        }

        // F3: app launch 后台预热当前 engine.100ms 延迟保险:给 VoiceJarDelegate.requestPermissions
        // 的 TCC callback 一个落地窗口,消除两个 TCC 请求精确同帧 race(Phase 2E-a Thread 3 教训)
        schedulePrepare(for: asrProvider)
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
        overlayWindow?.setStyle(next)
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

        // Phase 2E-a:通过 ASRProvider 启动流式识别(provider 自管 mic + 60s rotation)
        let language = appState.recognitionLanguage.rawValue
        let vocab = appState.vocab.activeTerms

        // 乐观 set 状态:startStreaming 几 ms 内通常返回;失败时 Task catch 内回滚
        recordingStartTime = Date()
        appState.isRecording = true
        appState.statusMessage = "正在录音…"
        showOverlay()

        let provider = asrProvider
        streamingTask = Task { @MainActor [weak self] in
            do {
                try await provider.startStreaming(
                    language: language,
                    vocabHint: vocab,
                    onPartial: { [weak self] text in
                        // protocol @MainActor 已保证主线程,无需 DispatchQueue.main.async
                        self?.appState.liveText = text
                        self?.overlayWindow?.updateText(text)
                    },
                    onFinal: { [weak self] text in
                        // Phase 3-A (P3=B):final 段在 VoiceEngine 层做 vocab 拼写矫正,
                        // 让下游 polish / inject 都拿到正确专名拼写.partial 不矫正(P4=A).
                        guard let self else { return }
                        let corrected = VocabPostprocessor.apply(text, vocab: self.appState.vocab.entries)
                        self.appState.liveText = corrected
                        self.appState.rawTranscription = corrected
                        self.overlayWindow?.updateText(corrected)
                        if corrected != text {
                            self.log("✅ 最终识别结果(已矫正): \(corrected)  ⟵  \(text)")
                        } else {
                            self.log("✅ 最终识别结果: \(corrected)")
                        }
                    },
                    onError: { [weak self] error in
                        self?.handleASRError(error)
                    }
                )
                self?.log("✅ 流式录音已启动")
            } catch let asrError as ASRError {
                self?.log("❌ 流式录音启动失败: \(asrError)")
                self?.handleASRError(asrError)
                self?.appState.isRecording = false
                self?.hideOverlay()
            } catch {
                self?.log("❌ 流式录音启动失败(非 ASRError): \(error)")
                self?.appState.errorMessage = "录音启动失败: \(error.localizedDescription)"
                self?.appState.isRecording = false
                self?.hideOverlay()
            }
        }
    }

    /// 统一处理 ASRError — ASRError enum 替代旧 NSError code 1110 判断(E5)
    @MainActor
    private func handleASRError(_ error: ASRError) {
        switch error {
        case .noSpeechDetected:
            // 等价旧 code == 1110:用户可能还没开始说,不报错
            log("🔇 未检测到语音")
        case .unauthorized:
            appState.errorMessage = "缺少语音识别或麦克风权限,请在系统设置中授权"
            log("⚠️ ASR 权限不足")
        case .unavailable:
            appState.errorMessage = "语音识别服务不可用"
            log("⚠️ ASR 不可用")
        case .modelMissing:
            appState.errorMessage = "ASR 模型未就绪"
            log("⚠️ 模型缺失")
        case .modelLoadFailed(let e):
            appState.errorMessage = "模型加载失败: \(e.localizedDescription)"
            log("❌ 模型加载失败: \(e)")
        case .underlying(let e):
            appState.errorMessage = "识别错误: \(e.localizedDescription)"
            log("❌ 识别错误: \(e)")
        }
    }

    func stopRecordingAndProcess() {
        guard appState.isRecording else { return }

        let duration = recordingStartTime.map { Date().timeIntervalSince($0) } ?? 0
        log("⏹️ 停止录音，时长: \(String(format: "%.1f", duration))秒")

        // E3 决策 A:fire-and-forget stop,不 await — 主路径立即读 appState.liveText(由
        // onPartial 持续累积到最后一刻)走 polish;onFinal 后续到达也只是覆盖 liveText
        let provider = asrProvider
        Task { await provider.stopStreaming() }

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

        // 1. 录音 + ASR — provider 内部处理 60s rotation + mic 停起,VoiceEngine 不感知
        asrProvider.cancel()
        streamingTask?.cancel()
        streamingTask = nil

        // HotkeyManager 内部 isRecording 必须同步关掉 — 否则用户松开 Fn 时
        // 第二次触发 onRecordStop，进 stopRecordingAndProcess 撞 guard 静默 return，
        // 状态机不一致，下次按快捷键也起不来
        hotkeyManager.syncRecordingStopped()

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

    // MARK: - ASR Provider 管理(Phase 2F)

    /// 工厂方法 — 根据 engine 枚举值实例化对应 provider.
    /// 注:静态方法显式 @MainActor 因为 SFSpeech/WhisperKit Provider 都是 @MainActor class,
    /// init 期间 self 尚未就绪,必须用 static 路径调用.
    @MainActor
    private static func makeProvider(for engine: ASREngine) -> any ASRProvider {
        switch engine {
        case .sfSpeech: return SFSpeechProvider()
        case .whisperKit: return WhisperKitProvider()
        }
    }

    /// F8: cancel 旧 provider + 创建新 + 后台 prepare.
    /// F7 兜底:录音/处理中拒绝切换(UI 已 disable,defense-in-depth)
    private func swapProvider(to newEngine: ASREngine) {
        if appState.isRecording || appState.isProcessing || appState.isTranslating {
            log("⚠️ ASR 切换被拦截:正在录音/处理中(UI 应 disable 此入口)")
            return
        }
        let oldEngineID = type(of: asrProvider).id
        if oldEngineID == newEngine {
            log("⏭️ ASR 切换:目标与当前相同(\(newEngine.rawValue)),忽略")
            return
        }
        log("🔄 ASR 切换: \(oldEngineID.rawValue) → \(newEngine.rawValue)")
        asrProvider.cancel()
        asrProvider = Self.makeProvider(for: newEngine)
        appState.asrModelStatusMessage = "正在准备 \(asrProvider.displayName)..."
        schedulePrepare(for: asrProvider)
    }

    /// 调度后台 prepare — 100ms 启动延迟保险 + 错误回退到 sfSpeech(F6)
    private func schedulePrepare(for provider: any ASRProvider) {
        let providerID = type(of: provider).id
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000)  // F3 保险
            guard let self else { return }
            self.log("⏳ 开始 prepare: \(providerID.rawValue)")
            do {
                try await provider.prepare { @Sendable [weak self] event in
                    // progress callback 是 @Sendable,不能直接访 @MainActor self
                    Task { @MainActor [weak self] in
                        self?.handlePrepareEvent(event, providerID: providerID)
                    }
                }
            } catch let asrError as ASRError {
                self.log("❌ prepare 失败: \(asrError)")
                self.handlePrepareFailure(asrError, attemptedEngine: providerID)
            } catch {
                self.log("❌ prepare 未知错误: \(error)")
                self.handlePrepareFailure(.underlying(error), attemptedEngine: providerID)
            }
        }
    }

    /// 处理 prepare 进度事件 — 防御:provider 已切换则丢弃过期事件
    private func handlePrepareEvent(_ event: ASRPrepareEvent, providerID: ASREngine) {
        guard providerID == type(of: asrProvider).id else {
            log("🔇 丢弃过期 prepare 事件(provider 已切换): \(providerID.rawValue)")
            return
        }
        switch event {
        case .downloadStarted(let bytes):
            let mb = bytes / 1_000_000
            appState.asrModelStatusMessage = "下载模型中(~\(mb) MB,首次约需几分钟)..."
        case .downloadProgress(let frac):
            appState.asrModelStatusMessage = "下载进度: \(Int(frac * 100))%"
        case .loading:
            appState.asrModelStatusMessage = "加载模型中..."
        case .ready:
            appState.asrModelStatusMessage = "\(asrProvider.displayName) 已就绪"
            log("✅ ASR 已就绪: \(providerID.rawValue)")
        }
    }

    /// F6: prepare 失败回滚到 sfSpeech.防御:用户期间又切了别的 engine 则不动
    private func handlePrepareFailure(_ error: ASRError, attemptedEngine: ASREngine) {
        appState.asrModelStatusMessage = "引擎准备失败: \(error.localizedDescription ?? "未知错误")"
        // 只在 1) 失败的不是 sfSpeech 本身 + 2) 用户当前仍指向失败引擎 时才回滚
        if attemptedEngine != .sfSpeech, appState.asrEngine == attemptedEngine {
            appState.errorMessage = "ASR 引擎准备失败,已自动回退到内置 macOS Speech"
            log("⏮️ 回滚 asrEngine → sfSpeech")
            appState.asrEngine = .sfSpeech  // didSet → Notification → swapProvider → 重新 prepare
        }
    }

    // MARK: - 浮窗

    private func showOverlay() {
        if overlayWindow == nil {
            overlayWindow = OverlayWindow()
        }
        overlayWindow?.setStyle(appState.outputStyle.defaultStyle)
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
