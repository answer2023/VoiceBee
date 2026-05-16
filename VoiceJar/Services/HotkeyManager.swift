import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 全局快捷键管理 — Phase 3-B 重构.
///
/// 支持四种组合:
/// - `.modifierOnly(.fn, .hold)` — 经典 Fn 按住说话
/// - `.modifierOnly(.rightCommand, .toggle)` — 右 ⌘ 单击切换录音
/// - `.combo(kVK_Space, .maskAlternate, .hold)` — ⌥Space 按住
/// - `.combo(kVK_V, [.maskCommand, .maskShift], .toggle)` — ⌘⇧V 单击切换
///
/// L/R modifier 通过 flagsChanged 事件的物理 keyCode 区分(F4=B).
/// Toggle 模式 30 分钟硬超时(F3=B).
///
/// @unchecked Sendable 安全说明:所有可变状态仅在主线程访问
/// (event tap 绑定到主 RunLoop,回调和 Timer 均在主线程执行).
final class HotkeyManager: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRecording = false

    /// 双击检测窗口(单 modifier 模式 hold mode 才有意义)
    private var lastModifierReleaseTime: CFAbsoluteTime = 0
    private var lastModifierPressTime: CFAbsoluteTime = 0
    private var pendingRecordStart: DispatchWorkItem?

    /// Toggle 模式 30 分钟硬超时(F3=B)
    private var toggleTimeoutTimer: DispatchSourceTimer?
    private static let toggleTimeoutSeconds: TimeInterval = 30 * 60

    /// 当前绑定的快捷键
    var hotkey: Hotkey = .fnHold

    /// 设置窗口活跃时暂停翻译快捷键拦截(避免录制时被消费)
    var suppressTranslateHotkey = false

    /// 全局暂停 — 菜单栏切换.true 时所有快捷键事件都直接放行不消费、不触发回调.
    /// 注意:Esc 取消仍生效(它是为了让用户取消已经在跑的录音/润色,与暂停状态无关).
    var isPaused = false

    var onRecordStart: (@Sendable () -> Void)?
    var onRecordStop: (@Sendable () -> Void)?
    /// 双击 modifier-only(hold 模式)回调 — 沿用旧 Fn 双击切换风格行为
    var onDoubleTap: (@Sendable () -> Void)?
    /// Toggle 模式 30 分钟超时回调(F3=B):VoiceEngine 接此 callback 走 stop + 用户反馈
    var onToggleTimeout: (@Sendable () -> Void)?

    /// 翻译快捷键及回调(单击触发,要求 .combo 编码)
    var translateHotkey: Hotkey = .loadTranslateHotkey()
    var onTranslate: (@Sendable () -> Void)?

    /// "重复粘贴上次结果"快捷键及回调(单击触发,要求 .combo 编码)
    var repeatLastHotkey: Hotkey = .loadRepeatLastHotkey()
    var onRepeatLast: (@Sendable () -> Void)?

    /// Esc 取消回调;仅在 isFlowActive() 返回 true 时拦截 Esc 并触发
    var onCancel: (@Sendable () -> Void)?
    var isFlowActive: (@Sendable () -> Bool)?

    /// 翻译触发键(Shift / Control / Option / Fn)— 录音中单击切换翻译标记
    /// 主线程读写;nil 表示禁用
    var translationTriggerMask: CGEventFlags?
    /// 触发键单击的切换回调;参数 = 切换后的状态(true = 已标记翻译)
    var onTranslateMidRecording: (@Sendable (Bool) -> Void)?
    /// 当前是否已标记本次录音翻译(每次新录音前由 VoiceEngine 重置)
    var translateMarked: Bool = false

    private var triggerKeyDownTime: CFAbsoluteTime = 0
    private var triggerKeyDownPending: Bool = false  // trigger 修饰键当前处于按下状态
    private var triggerKeyDownHadOtherEvent: Bool = false  // 期间有其他 keyDown 介入

    @discardableResult
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private static func log(_ msg: String) {
        VJLog.log(msg, prefix: "Hotkey")
    }

    private var accessibilityTimer: Timer?

    func startListening() {
        let accessible = AXIsProcessTrusted()
        HotkeyManager.log("辅助功能权限(AXIsProcessTrusted): \(accessible)")
        guard accessible else {
            HotkeyManager.log("⚠️ 未授权辅助功能,快捷键无法工作!请在 系统设置→隐私与安全→辅助功能 中添加 VoiceBee")
            Self.checkAccessibility(prompt: true)
            startAccessibilityPolling()
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            HotkeyManager.log("❌ CGEvent tap 创建失败")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        HotkeyManager.log("✅ 快捷键监听启动成功: \(hotkey.displayName) (\(hotkey.mode.displayName))")
    }

    func rebind(to combo: Hotkey) {
        // 切换 hotkey 时,如果正在 toggle 录音,先停掉(避免新 hotkey 接管时旧状态卡住)
        if isRecording {
            isRecording = false
            cancelToggleTimeout()
            let cb = onRecordStop
            DispatchQueue.main.async { cb?() }
        }
        pendingRecordStart?.cancel()
        pendingRecordStart = nil
        hotkey = combo
        HotkeyManager.log("🔄 快捷键已切换为: \(combo.displayName) (\(combo.mode.displayName))")
    }

    /// 由 VoiceEngine 在 cancelInFlight / 暂停切换时调用,把内部 isRecording 标志同步回 false.
    /// 不触发 onRecordStop 回调(VoiceEngine 已经自己处理状态),只对齐状态机.
    func syncRecordingStopped() {
        isRecording = false
        cancelToggleTimeout()
        pendingRecordStart?.cancel()
        pendingRecordStart = nil
    }

    /// 系统有时会自动关闭 event tap(超时等原因),定期检查并重新启用
    private func ensureTapEnabled() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            HotkeyManager.log("⚠️ Event tap 被系统关闭,正在重新启用…")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        ensureTapEnabled()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Esc 取消:仅在 VoiceBee 流程活跃时拦截,否则让事件穿透
        if type == .keyDown && keyCode == 53 {  // kVK_Escape
            if isFlowActive?() == true, let cb = onCancel {
                HotkeyManager.log("🛑 Esc 拦截 → 触发取消")
                DispatchQueue.main.async { cb() }
                return true
            }
            return false
        }

        // 全局暂停:所有其他快捷键直接放行,不消费、不触发回调.
        // 关键:若暂停瞬间正在录音,必须同步关掉内部状态,否则状态机卡死.
        if isPaused {
            if isRecording {
                isRecording = false
                cancelToggleTimeout()
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            }
            triggerKeyDownPending = false
            pendingRecordStart?.cancel()
            pendingRecordStart = nil
            return false
        }

        // 翻译触发键单击检测(仅录音中生效,不消费事件让透传给前台 App)
        if isRecording, let triggerMask = translationTriggerMask {
            if type == .flagsChanged {
                let triggerHeld = flags.contains(triggerMask)
                if triggerHeld && !triggerKeyDownPending {
                    triggerKeyDownPending = true
                    triggerKeyDownTime = CFAbsoluteTimeGetCurrent()
                    triggerKeyDownHadOtherEvent = false
                } else if !triggerHeld && triggerKeyDownPending {
                    let dur = CFAbsoluteTimeGetCurrent() - triggerKeyDownTime
                    let isSingleTap = dur < 0.8 && !triggerKeyDownHadOtherEvent
                    triggerKeyDownPending = false
                    if isSingleTap {
                        translateMarked.toggle()
                        let marked = translateMarked
                        HotkeyManager.log("🌐 录音中触发键单击 → 翻译标记 \(marked ? "ON" : "OFF")")
                        let cb = onTranslateMidRecording
                        DispatchQueue.main.async { cb?(marked) }
                    }
                }
            } else if type == .keyDown && triggerKeyDownPending {
                triggerKeyDownHadOtherEvent = true
            }
        }

        // 翻译快捷键(单击触发,消费事件防字符输入)
        if type == .keyDown && !isRecording && translateHotkey.comboMatchesExact(keyCode: keyCode, flags: flags) {
            if suppressTranslateHotkey {
                HotkeyManager.log("🌐 翻译快捷键匹配但被抑制(设置窗口活跃)")
                return false
            }
            HotkeyManager.log("🌐 翻译快捷键触发")
            let cb = onTranslate
            DispatchQueue.main.async { cb?() }
            return true
        }

        // 重复粘贴上次结果快捷键(单击触发)
        if type == .keyDown && !isRecording && repeatLastHotkey.comboMatchesExact(keyCode: keyCode, flags: flags) {
            if suppressTranslateHotkey {
                HotkeyManager.log("📋 重复粘贴快捷键匹配但被抑制(设置窗口活跃)")
                return false
            }
            HotkeyManager.log("📋 重复粘贴快捷键触发")
            let cb = onRepeatLast
            DispatchQueue.main.async { cb?() }
            return true
        }

        // 调试:记录所有 flagsChanged 事件(只在 main hotkey 是 modifier-only 时打,
        // 否则日志爆炸)
        if type == .flagsChanged && hotkey.isModifierOnly {
            HotkeyManager.log("flagsChanged: keyCode=\(keyCode) flags=\(flags.rawValue)")
        }

        // 主 hotkey 分发:按 case 走不同事件路径
        switch hotkey {
        case .modifierOnly(let mk, let mode):
            handleModifierOnly(mk: mk, mode: mode, type: type, keyCode: keyCode, flags: flags)
        case .combo(let kc, let mods, let mode):
            handleCombo(kc: kc, mods: mods, mode: mode, type: type, keyCode: keyCode, flags: flags)
        }
        return false
    }

    // MARK: - modifier-only 事件处理

    private func handleModifierOnly(mk: ModifierKey, mode: HotkeyMode, type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        // 我们只关心 flagsChanged + 对应物理 keyCode 的事件
        guard type == .flagsChanged else { return }
        guard keyCode == Int64(mk.physicalKeyCode) else { return }

        // 状态:本次 flagsChanged 后,我们的目标 modifier 是否处于按下状态.
        // CGEventFlags 不区分左右,但因为我们已经过滤了物理 keyCode,这里的 flag bit on/off
        // 就代表"我们配置的这个具体物理键"的状态变化.
        // 边界情况:若用户同时按住左右两个同类型 modifier(如左⌘+右⌘),释放其中一个时
        // flag bit 仍 on — 这时 nowPressed 会一直为 true,直到全部松开.可接受(罕见).
        let nowPressed = flags.contains(mk.flagMask)

        switch mode {
        case .hold:
            handleHoldModifierOnly(mk: mk, nowPressed: nowPressed)
        case .toggle:
            // Toggle 只响应按下,忽略松开
            if nowPressed {
                handleToggleTrigger(label: mk.displayName)
            }
        }
    }

    private func handleHoldModifierOnly(mk: ModifierKey, nowPressed: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        if nowPressed {
            let timeSinceLastRelease = now - lastModifierReleaseTime

            // 双击检测:距上次松开 < 0.35秒
            if timeSinceLastRelease < 0.35 && !isRecording {
                pendingRecordStart?.cancel()
                pendingRecordStart = nil
                HotkeyManager.log("🔄 检测到双击 \(mk.displayName) — 触发 onDoubleTap")
                lastModifierPressTime = now
                let cb = onDoubleTap
                DispatchQueue.main.async { cb?() }
                return
            }

            lastModifierPressTime = now

            if !isRecording {
                // 延迟 200ms 启动录音,给双击检测留窗口
                let work = DispatchWorkItem { [weak self] in
                    guard let self, !self.isRecording else { return }
                    self.isRecording = true
                    let cb = self.onRecordStart
                    DispatchQueue.main.async { cb?() }
                }
                pendingRecordStart = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            }
        } else {
            // 松开
            lastModifierReleaseTime = now
            if let pending = pendingRecordStart, !pending.isCancelled {
                pending.cancel()
                pendingRecordStart = nil
            }
            if isRecording {
                isRecording = false
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            }
        }
    }

    // MARK: - combo 事件处理

    private func handleCombo(kc: Int, mods: CGEventFlags, mode: HotkeyMode, type: CGEventType, keyCode: Int64, flags: CGEventFlags) {
        let matchesPress = hotkey.comboMatches(keyCode: keyCode, flags: flags)

        switch mode {
        case .hold:
            if type == .keyDown && matchesPress && !isRecording {
                isRecording = true
                let cb = onRecordStart
                DispatchQueue.main.async { cb?() }
            } else if type == .keyUp && Int64(kc) == keyCode && isRecording {
                isRecording = false
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            } else if type == .flagsChanged && isRecording && !hotkey.comboModifierStillHeld(flags: flags) {
                // 修饰键释放兜底:即使没有 keyUp,modifier 没了也停
                isRecording = false
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            }
        case .toggle:
            // 只响应 keyDown — 单击切换录音
            if type == .keyDown && matchesPress {
                handleToggleTrigger(label: hotkey.displayName)
            }
        }
    }

    // MARK: - Toggle 模式公共状态切换 + 30 分钟超时

    private func handleToggleTrigger(label: String) {
        if isRecording {
            isRecording = false
            cancelToggleTimeout()
            HotkeyManager.log("⏹ Toggle 停止录音: \(label)")
            let cb = onRecordStop
            DispatchQueue.main.async { cb?() }
        } else {
            isRecording = true
            scheduleToggleTimeout(label: label)
            HotkeyManager.log("⏺ Toggle 开始录音: \(label)")
            let cb = onRecordStart
            DispatchQueue.main.async { cb?() }
        }
    }

    private func scheduleToggleTimeout(label: String) {
        cancelToggleTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.toggleTimeoutSeconds)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isRecording else { return }
            self.isRecording = false
            self.toggleTimeoutTimer = nil
            HotkeyManager.log("⚠️ Toggle 录音超 \(Int(Self.toggleTimeoutSeconds / 60)) 分钟 (\(label)),自动停止")
            // 优先回 onToggleTimeout 让 VoiceEngine 走专属反馈路径;
            // 若 VoiceEngine 没接,fallback 走正常 onRecordStop(确保流程能落)
            let timeoutCb = self.onToggleTimeout
            let stopCb = self.onRecordStop
            DispatchQueue.main.async {
                if let timeoutCb {
                    timeoutCb()
                } else {
                    stopCb?()
                }
            }
        }
        timer.resume()
        toggleTimeoutTimer = timer
    }

    private func cancelToggleTimeout() {
        toggleTimeoutTimer?.cancel()
        toggleTimeoutTimer = nil
    }

    /// 每2秒检查辅助功能权限,授权后自动开始监听
    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        HotkeyManager.log("🔄 开始轮询辅助功能权限(每2秒)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] t in
                HotkeyManager.log("🔍 轮询检查辅助功能权限...")
                let trusted = AXIsProcessTrusted()
                HotkeyManager.log("🔍 AXIsProcessTrusted = \(trusted)")
                if trusted {
                    HotkeyManager.log("✅ 辅助功能权限已获取,自动启动监听")
                    t.invalidate()
                    self?.accessibilityTimer = nil
                    self?.startListening()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.accessibilityTimer = timer
            HotkeyManager.log("✅ 轮询 Timer 已加入主线程 RunLoop")
        }
    }

    func stopListening() {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        cancelToggleTimeout()
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit { stopListening() }
}

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
    let consumed = manager.handleCGEvent(type: type, event: event)
    return consumed ? nil : Unmanaged.passUnretained(event)
}
