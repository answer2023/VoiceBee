import AppKit
import AVFoundation
import SwiftUI
import Speech

@main
struct VoiceJarMain {
    static func main() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voicejar_debug.log")
        try? "MAIN ENTRY\n".data(using: .utf8)?.write(to: url)

        // 单实例锁：若已有 VoiceBee 在运行，激活旧实例并退出
        if let existing = Self.findExistingInstance() {
            existing.activate()
            exit(0)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = VoiceJarDelegate()
        app.delegate = delegate

        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write("BEFORE app.run()\n".data(using: .utf8)!)
            handle.closeFile()
        }

        app.run()
    }

    private static func findExistingInstance() -> NSRunningApplication? {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.clearsky.VoiceJar"
        let myPID = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != myPID }
    }
}

@MainActor
class VoiceJarDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var appState: AppState!
    private var engine: VoiceEngine?
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    private func log(_ msg: String) {
        VJLog.log(msg, prefix: "App")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("applicationDidFinishLaunching")

        appState = AppState()
        log("AppState 创建完成")

        // 菜单栏
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "mic", accessibilityDescription: "VoiceBee")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        log("菜单栏图标已创建")

        // 添加 Edit 菜单（accessory app 没有默认菜单栏，⌘V 等快捷键不工作）
        let mainMenu = NSMenu()
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = {
            let menu = NSMenu(title: "Edit")
            menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            menu.addItem(withTitle: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
            menu.addItem(withTitle: "Redo", action: NSSelectorFromString("redo:"), keyEquivalent: "Z")
            return menu
        }()
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu

        // 监听通知
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings(_:)),
            name: .openSettings, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openHistory),
            name: .openHistory, object: nil
        )

        // 主动请求权限（防止二进制更新后权限失效）
        requestPermissions()

        // 引擎
        engine = VoiceEngine(appState: appState)
        log("引擎已启动, 快捷键: \(appState.hotkey.displayName)")

        // 自动更新（Sparkle 会按 SUScheduledCheckInterval 周期检查）
        _ = UpdaterManager.shared
        log("Sparkle updater 已启动")

        // 首次启动引导
        if !UserDefaults.standard.bool(forKey: "onboardingCompleted") {
            showOnboarding()
        }

        // 状态驱动刷新图标
        startObservingRecordingState()
    }

    private func requestPermissions() {
        // 辅助功能：清除过期 TCC 条目 + 弹出授权提示
        if !AXIsProcessTrusted() {
            log("⚠️ 辅助功能未授权，清除过期 TCC 条目并重新请求")
            // 清除旧签名留下的过期授权（解决更新后开关显示 ON 但实际无效的问题）
            let tccReset = Process()
            tccReset.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            tccReset.arguments = ["reset", "Accessibility", "com.clearsky.VoiceJar"]
            try? tccReset.run()
            tccReset.waitUntilExit()
            log("🔄 已重置辅助功能 TCC 条目")
            // 弹出干净的授权提示
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        // 麦克风
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .notDetermined {
            log("🎤 请求麦克风权限")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.log("🎤 麦克风权限: \(granted ? "已授权" : "被拒绝")")
            }
        }

        // 语音识别
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            log("🗣️ 请求语音识别权限")
            SFSpeechRecognizer.requestAuthorization { status in
                self.log("🗣️ 语音识别权限: \(status == .authorized ? "已授权" : "状态 \(status.rawValue)")")
            }
        }
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showContextMenu()
        } else {
            openSettings(Notification(name: .openSettings))
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let historyItem = NSMenuItem(title: "语音历史", action: #selector(openHistory), keyEquivalent: "")
        historyItem.target = self
        historyItem.isEnabled = !appState.history.isEmpty
        menu.addItem(historyItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 VoiceBee", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Reset menu so left-click doesn't trigger it next time
        statusItem.menu = nil
    }

    private func showOnboarding() {
        let onboardingView = OnboardingView {
            UserDefaults.standard.set(true, forKey: "onboardingCompleted")
            self.onboardingWindow?.close()
            self.onboardingWindow = nil
        }

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "欢迎使用 VoiceBee"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        onboardingWindow = window
    }

    @objc private func openHistory() {
        if let window = historyWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(
            rootView: HistoryView().environment(appState!)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "语音历史"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        historyWindow = window
    }

    @objc private func openSettings(_ notification: Notification) {
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let state: AppState = appState
        let hostingController = NSHostingController(
            rootView: SettingsView().environment(state)
        )

        let window = NSWindow(contentViewController: hostingController)
        window.title = "VoiceBee 设置"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
        engine?.suppressTranslateHotkey(true)
    }

    /// 通过 withObservationTracking 监听 isRecording 变化，按需刷新菜单栏图标
    private func startObservingRecordingState() {
        withObservationTracking {
            _ = self.appState.isRecording
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.updateStatusBarIcon()
                self?.startObservingRecordingState()
            }
        }
    }

    private func updateStatusBarIcon() {
        guard let button = statusItem?.button else { return }
        let icon = appState.isRecording ? "mic.fill" : "mic"
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        image?.isTemplate = true
        button.image = image
    }
}

extension VoiceJarDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === settingsWindow {
            settingsWindow = nil
            engine?.suppressTranslateHotkey(false)
        } else if window === historyWindow {
            historyWindow = nil
        } else if window === onboardingWindow {
            onboardingWindow = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === settingsWindow {
            engine?.suppressTranslateHotkey(false)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let window = notification.object as? NSWindow
        if window === settingsWindow {
            engine?.suppressTranslateHotkey(true)
        }
    }
}
