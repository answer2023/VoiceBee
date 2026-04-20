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

    var onRecordStart: (@Sendable () -> Void)?
    var onRecordStop: (@Sendable () -> Void)?
    /// 双击 Fn 回调
    var onDoubleTap: (@Sendable () -> Void)?

    /// 翻译快捷键及回调（单击触发）
    var translateHotkey: HotkeyCombo = HotkeyCombo.loadTranslateHotkey()
    var onTranslate: (@Sendable () -> Void)?

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
        print("🔄 快捷键已切换为: \(combo.displayName)")
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
