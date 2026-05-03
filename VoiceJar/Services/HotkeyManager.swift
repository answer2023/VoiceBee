import AppKit
import Carbon.HIToolbox
import ApplicationServices

/// 全局快捷键管理 — 支持 Fn 单键 / 组合键
/// @unchecked Sendable 安全说明：所有可变状态仅在主线程访问
/// （event tap 绑定到主 RunLoop，回调和 Timer 均在主线程执行）
final class HotkeyManager: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isRecording = false
    private var lastFnReleaseTime: CFAbsoluteTime = 0
    private var lastFnPressTime: CFAbsoluteTime = 0
    private var pendingRecordStart: DispatchWorkItem?

    /// 当前绑定的快捷键
    var hotkey: HotkeyCombo = .fn

    /// 设置窗口活跃时暂停翻译快捷键拦截（避免录制时被消费）
    var suppressTranslateHotkey = false

    /// 全局暂停 — 菜单栏切换。true 时所有快捷键事件都直接放行不消费、不触发回调
    /// 注意：Esc 取消仍生效（它是为了让用户取消已经在跑的录音/润色，与暂停状态无关）
    var isPaused = false

    var onRecordStart: (@Sendable () -> Void)?
    var onRecordStop: (@Sendable () -> Void)?
    /// 双击 Fn 回调
    var onDoubleTap: (@Sendable () -> Void)?

    /// 翻译快捷键及回调（单击触发）
    var translateHotkey: HotkeyCombo = HotkeyCombo.loadTranslateHotkey()
    var onTranslate: (@Sendable () -> Void)?

    /// "重复粘贴上次结果"快捷键及回调（单击触发）
    var repeatLastHotkey: HotkeyCombo = HotkeyCombo.loadRepeatLastHotkey()
    var onRepeatLast: (@Sendable () -> Void)?

    /// Esc 取消回调；仅在 isFlowActive() 返回 true 时拦截 Esc 并触发
    var onCancel: (@Sendable () -> Void)?
    var isFlowActive: (@Sendable () -> Bool)?

    /// 翻译触发键（Shift / Control / Option / Fn）— 录音中单击切换翻译标记
    /// 主线程读写；nil 表示禁用
    var translationTriggerMask: CGEventFlags?
    /// 触发键单击的切换回调；参数 = 切换后的状态（true = 已标记翻译）
    var onTranslateMidRecording: (@Sendable (Bool) -> Void)?
    /// 当前是否已标记本次录音翻译（每次新录音前由 VoiceEngine 重置）
    var translateMarked: Bool = false

    private var triggerKeyDownTime: CFAbsoluteTime = 0
    private var triggerKeyDownPending: Bool = false  // trigger 修饰键当前处于按下状态
    private var triggerKeyDownHadOtherEvent: Bool = false  // 期间有其他 keyDown 介入

    @discardableResult
    static func checkAccessibility(prompt: Bool = true) -> Bool {
        // kAXTrustedCheckOptionPrompt 的实际值是 "AXTrustedCheckOptionPrompt"
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
            HotkeyManager.log("⚠️ 未授权辅助功能，快捷键无法工作！请在 系统设置→隐私与安全→辅助功能 中添加 VoiceBee")
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

        HotkeyManager.log("✅ 快捷键监听启动成功: \(hotkey.displayName)")
    }

    func rebind(to combo: HotkeyCombo) {
        hotkey = combo
        HotkeyManager.log("🔄 快捷键已切换为: \(combo.displayName)")
    }

    /// 由 VoiceEngine 在 cancelInFlight / 暂停切换时调用，把内部 isRecording 标志同步回 false。
    /// 不触发 onRecordStop 回调（VoiceEngine 已经自己处理状态），只对齐状态机。
    func syncRecordingStopped() {
        isRecording = false
        triggerKeyDownPending = false
        pendingRecordStart?.cancel()
        pendingRecordStart = nil
    }

    /// 系统有时会自动关闭 event tap（超时等原因），定期检查并重新启用
    private func ensureTapEnabled() {
        guard let tap = eventTap else { return }
        if !CGEvent.tapIsEnabled(tap: tap) {
            HotkeyManager.log("⚠️ Event tap 被系统关闭，正在重新启用…")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    fileprivate func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        // 检查 tap 是否被系统关闭
        ensureTapEnabled()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Esc 取消：仅在 VoiceBee 流程活跃时拦截，否则让事件穿透
        // 暂停状态下也保留 — 已经在跑的流程（pause 之前启动的）仍允许 Esc 终止
        if type == .keyDown && keyCode == 53 {  // kVK_Escape
            if isFlowActive?() == true, let cb = onCancel {
                HotkeyManager.log("🛑 Esc 拦截 → 触发取消")
                DispatchQueue.main.async { cb() }
                return true  // 消费事件，避免被前台 App 当作 Esc
            }
            return false
        }

        // 全局暂停：所有其他快捷键直接放行，不消费、不触发回调
        // 关键：若暂停瞬间正在录音，必须把内部 isRecording / 待启动 timer 同步关掉，
        // 否则后续 flagsChanged 永远走不到「修饰键松开 → onRecordStop」分支，
        // 状态机卡死，恢复后再按快捷键也起不来。
        if isPaused {
            if isRecording {
                isRecording = false
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            }
            triggerKeyDownPending = false
            pendingRecordStart?.cancel()
            pendingRecordStart = nil
            return false
        }

        // 翻译触发键单击检测（仅录音中生效，不消费事件让透传给前台 App）
        if isRecording, let triggerMask = translationTriggerMask {
            if type == .flagsChanged {
                let triggerHeld = flags.contains(triggerMask)
                if triggerHeld && !triggerKeyDownPending {
                    // 触发键按下：起算时长 + 清空"期间被打断"标记
                    triggerKeyDownPending = true
                    triggerKeyDownTime = CFAbsoluteTimeGetCurrent()
                    triggerKeyDownHadOtherEvent = false
                } else if !triggerHeld && triggerKeyDownPending {
                    // 触发键松开：判断是否「单击」（< 800ms + 期间无其他键事件）
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
                // 期间有其他 keyDown → 这是组合键（如 Shift+A），不算单击
                triggerKeyDownHadOtherEvent = true
            }
        }

        // 翻译快捷键（单击触发，消费事件防止字符输入）
        // suppressTranslateHotkey 为 true 时跳过，让事件传到设置窗口的快捷键录制器
        if type == .keyDown && !isRecording && translateHotkey.matchesExact(keyCode: keyCode, flags: flags) {
            if suppressTranslateHotkey {
                HotkeyManager.log("🌐 翻译快捷键匹配但被抑制（设置窗口活跃）")
                return false
            }
            HotkeyManager.log("🌐 翻译快捷键触发")
            let cb = onTranslate
            DispatchQueue.main.async { cb?() }
            return true
        }

        // 重复粘贴上次结果快捷键（单击触发）
        // 同样在 suppressTranslateHotkey 期间放行，让设置窗口的录制器能捕获
        if type == .keyDown && !isRecording && repeatLastHotkey.matchesExact(keyCode: keyCode, flags: flags) {
            if suppressTranslateHotkey {
                HotkeyManager.log("📋 重复粘贴快捷键匹配但被抑制（设置窗口活跃）")
                return false
            }
            HotkeyManager.log("📋 重复粘贴快捷键触发")
            let cb = onRepeatLast
            DispatchQueue.main.async { cb?() }
            return true
        }

        // 调试：记录所有 flagsChanged 事件
        if type == .flagsChanged {
            HotkeyManager.log("flagsChanged: keyCode=\(keyCode) flags=\(flags.rawValue) fn=\(flags.contains(.maskSecondaryFn))")
        }

        // Fn 单键模式：通过 flagsChanged 检测 + 双击检测
        if hotkey.isFnOnly {
            if type == .flagsChanged {
                let fnHeld = flags.contains(.maskSecondaryFn)
                let now = CFAbsoluteTimeGetCurrent()

                if fnHeld {
                    // Fn 按下
                    let timeSinceLastRelease = now - lastFnReleaseTime

                    // 双击检测：距上次松开 < 0.35秒
                    if timeSinceLastRelease < 0.35 && !isRecording {
                        // 取消待启动的录音
                        pendingRecordStart?.cancel()
                        pendingRecordStart = nil
                        HotkeyManager.log("🔄 检测到双击 Fn — 切换模式")
                        lastFnPressTime = now
                        let cb = onDoubleTap
                        DispatchQueue.main.async { cb?() }
                        return false
                    }

                    lastFnPressTime = now

                    if !isRecording {
                        // 延迟 200ms 启动录音，给双击检测留窗口
                        let work = DispatchWorkItem { [weak self] in
                            guard let self, !self.isRecording else { return }
                            self.isRecording = true
                            let cb = self.onRecordStart
                            DispatchQueue.main.async { cb?() }
                        }
                        pendingRecordStart = work
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
                    }
                } else if !fnHeld {
                    // Fn 松开
                    lastFnReleaseTime = now

                    // 如果录音还没真正开始（在 200ms 窗口内松开），取消
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
            return false
        }

        // 组合键模式（如 ⌥Space）
        if hotkey.matches(keyCode: keyCode, flags: flags) {
            if type == .keyDown && !isRecording {
                isRecording = true
                let cb = onRecordStart
                DispatchQueue.main.async { cb?() }
            } else if type == .keyUp && isRecording {
                isRecording = false
                let cb = onRecordStop
                DispatchQueue.main.async { cb?() }
            }
            return false
        }

        // 修饰键释放时也停止
        if type == .flagsChanged && isRecording && !hotkey.modifierStillHeld(flags: flags) {
            isRecording = false
            let cb = onRecordStop
            DispatchQueue.main.async { cb?() }
        }
        return false
    }

    /// 每2秒检查辅助功能权限，授权后自动开始监听
    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        HotkeyManager.log("🔄 开始轮询辅助功能权限（每2秒）")
        // 必须在主线程创建 Timer，否则非主线程 RunLoop 不活跃导致 timer 不触发
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] t in
                HotkeyManager.log("🔍 轮询检查辅助功能权限...")
                let trusted = AXIsProcessTrusted()
                HotkeyManager.log("🔍 AXIsProcessTrusted = \(trusted)")
                if trusted {
                    HotkeyManager.log("✅ 辅助功能权限已获取，自动启动监听")
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
