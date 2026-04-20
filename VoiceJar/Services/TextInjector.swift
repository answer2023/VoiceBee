import AppKit
import Carbon.HIToolbox

/// 文本注入服务 — 将文字输入到当前活跃 App 的光标位置
struct TextInjector {

    /// 通过模拟剪贴板粘贴注入文本（最可靠的方式）
    static func inject(_ text: String) {
        // 1. 保存当前剪贴板内容
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // 2. 写入新文本到剪贴板
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. 模拟 ⌘V 粘贴
        simulatePaste()

        // 4. 延迟恢复原剪贴板内容
        //    监测 changeCount 变化确认粘贴完成，最多等 1.5 秒
        let changeCount = pasteboard.changeCount
        restoreClipboard(previous: previousContents, expectedChangeCount: changeCount, attempt: 0)
    }

    /// 等待目标 App 消费粘贴事件后恢复剪贴板
    private static func restoreClipboard(previous: String?, expectedChangeCount: Int, attempt: Int) {
        let delay: TimeInterval = attempt == 0 ? 0.15 : 0.3
        let maxAttempts = 4 // 最多 0.15 + 0.3*3 = 1.05秒

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            let pasteboard = NSPasteboard.general
            // 如果 changeCount 变了，说明其他程序（或用户）修改了剪贴板，不再恢复
            guard pasteboard.changeCount == expectedChangeCount else { return }

            // 前几次检查：给慢速 App 更多时间
            if attempt < maxAttempts - 1 {
                restoreClipboard(previous: previous, expectedChangeCount: expectedChangeCount, attempt: attempt + 1)
                return
            }

            // 最后一次：恢复原内容
            if let previous {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
    }

    /// 模拟 ⌘C 复制选中文本
    private static func simulateCopy() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    /// 获取当前选中的文本（通过模拟 ⌘C）
    @MainActor
    static func grabSelectedText() async -> String? {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)
        let previousChangeCount = pasteboard.changeCount

        simulateCopy()

        // 等待目标 App 处理 ⌘C 并更新剪贴板
        try? await Task.sleep(nanoseconds: 150_000_000) // 150ms

        guard pasteboard.changeCount != previousChangeCount else {
            return nil // 没有选中文本或复制失败
        }

        let copiedText = pasteboard.string(forType: .string)

        // 恢复原剪贴板内容
        pasteboard.clearContents()
        if let previousContents {
            pasteboard.setString(previousContents, forType: .string)
        }

        return copiedText
    }

    /// 替换上次注入的文本（用于 AI 润色后自动替换原文）
    /// 通过 Cmd+Z 撤销上次粘贴，再粘贴新文本
    static func replaceLastInjection(oldLength: Int, newText: String) {
        guard oldLength > 0 else {
            inject(newText)
            return
        }

        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // 1. Cmd+Z 撤销上次粘贴
        simulateUndo()

        // 2. 等待撤销完成
        usleep(60_000) // 60ms

        // 3. 粘贴润色文本
        pasteboard.clearContents()
        pasteboard.setString(newText, forType: .string)
        simulatePaste()

        // 4. 恢复剪贴板
        let changeCount = pasteboard.changeCount
        restoreClipboard(previous: previousContents, expectedChangeCount: changeCount, attempt: 0)
    }

    /// 模拟 ⌘Z 撤销
    private static func simulateUndo() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_Z), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }

    /// 模拟 ⌘V 快捷键
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: V with Command
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
