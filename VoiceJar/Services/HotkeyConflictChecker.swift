import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// 快捷键冲突检测 — Phase 3-B (F6=A 系统黑名单 + F7=C 超集内部冲突).
///
/// 设计原则:
/// - 系统冲突 = 经验黑名单(常见 macOS shortcut),命中 → UI Alert 提示"可能不响应"
/// - 内部冲突 = VoiceBee 自家 hotkey 之间(main / translate / repeatLast / translation trigger)
/// - 系统冲突可被用户强制覆盖(F6 Alert "继续使用");内部冲突也只是警告,但 UI 应禁止保存重复
enum HotkeyConflictChecker {

    // MARK: - 系统冲突

    /// 系统冲突报告:label = 用户能看懂的描述,如 "Spotlight (⌘Space)"
    struct SystemConflict {
        let label: String
    }

    /// 检测此 hotkey 是否命中系统常用 shortcut.返回 nil = 无冲突.
    /// 注意:modifier-only hotkey(Fn / 右⌘ 等单 modifier)在 macOS 系统层没有 shortcut 占用
    /// (系统 shortcut 都是 modifier + key 组合),所以 modifier-only 永远返回 nil.
    static func systemConflict(for hotkey: Hotkey) -> SystemConflict? {
        guard case .combo(let kc, let mods, _) = hotkey else { return nil }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        let normalized = mods.intersection(relevant)
        for entry in systemBlacklist {
            let entryNorm = entry.modifiers.intersection(relevant)
            if entry.keyCode == kc && entryNorm == normalized {
                return SystemConflict(label: entry.label)
            }
        }
        return nil
    }

    private struct BlacklistEntry {
        let keyCode: Int
        let modifiers: CGEventFlags
        let label: String
    }

    /// 经验黑名单 — 常见 macOS 系统 shortcut.
    /// 不求完整(那是私有 API HISymbolicHotKey 的事),只覆盖最容易撞的几十个.
    private static let systemBlacklist: [BlacklistEntry] = [
        // ⌘ 单 modifier 组合
        BlacklistEntry(keyCode: kVK_Tab, modifiers: .maskCommand, label: "App 切换 (⌘Tab)"),
        BlacklistEntry(keyCode: kVK_Space, modifiers: .maskCommand, label: "Spotlight (⌘Space)"),
        BlacklistEntry(keyCode: kVK_ANSI_W, modifiers: .maskCommand, label: "关闭窗口 (⌘W)"),
        BlacklistEntry(keyCode: kVK_ANSI_Q, modifiers: .maskCommand, label: "退出 App (⌘Q)"),
        BlacklistEntry(keyCode: kVK_ANSI_H, modifiers: .maskCommand, label: "隐藏 App (⌘H)"),
        BlacklistEntry(keyCode: kVK_ANSI_M, modifiers: .maskCommand, label: "最小化窗口 (⌘M)"),
        BlacklistEntry(keyCode: kVK_ANSI_N, modifiers: .maskCommand, label: "新建 (⌘N)"),
        BlacklistEntry(keyCode: kVK_ANSI_O, modifiers: .maskCommand, label: "打开 (⌘O)"),
        BlacklistEntry(keyCode: kVK_ANSI_S, modifiers: .maskCommand, label: "保存 (⌘S)"),
        BlacklistEntry(keyCode: kVK_ANSI_P, modifiers: .maskCommand, label: "打印 (⌘P)"),
        BlacklistEntry(keyCode: kVK_ANSI_A, modifiers: .maskCommand, label: "全选 (⌘A)"),
        BlacklistEntry(keyCode: kVK_ANSI_C, modifiers: .maskCommand, label: "复制 (⌘C)"),
        BlacklistEntry(keyCode: kVK_ANSI_V, modifiers: .maskCommand, label: "粘贴 (⌘V)"),
        BlacklistEntry(keyCode: kVK_ANSI_X, modifiers: .maskCommand, label: "剪切 (⌘X)"),
        BlacklistEntry(keyCode: kVK_ANSI_Z, modifiers: .maskCommand, label: "撤销 (⌘Z)"),
        BlacklistEntry(keyCode: kVK_ANSI_F, modifiers: .maskCommand, label: "查找 (⌘F)"),
        BlacklistEntry(keyCode: kVK_ANSI_T, modifiers: .maskCommand, label: "新标签页 (⌘T)"),
        BlacklistEntry(keyCode: kVK_ANSI_R, modifiers: .maskCommand, label: "刷新/重做 (⌘R)"),
        // ⌘⇧ 组合
        BlacklistEntry(keyCode: kVK_ANSI_Z, modifiers: [.maskCommand, .maskShift], label: "重做 (⌘⇧Z)"),
        BlacklistEntry(keyCode: kVK_ANSI_3, modifiers: [.maskCommand, .maskShift], label: "全屏截图 (⌘⇧3)"),
        BlacklistEntry(keyCode: kVK_ANSI_4, modifiers: [.maskCommand, .maskShift], label: "区域截图 (⌘⇧4)"),
        BlacklistEntry(keyCode: kVK_ANSI_5, modifiers: [.maskCommand, .maskShift], label: "截图工具 (⌘⇧5)"),
        BlacklistEntry(keyCode: kVK_Tab, modifiers: [.maskCommand, .maskShift], label: "App 反向切换 (⌘⇧Tab)"),
        // F 系列功能键(裸按)
        BlacklistEntry(keyCode: kVK_F3, modifiers: [], label: "Mission Control (F3)"),
        BlacklistEntry(keyCode: kVK_F4, modifiers: [], label: "Launchpad/Spotlight (F4)"),
        BlacklistEntry(keyCode: kVK_F11, modifiers: [], label: "显示桌面 (F11)"),
        BlacklistEntry(keyCode: kVK_F12, modifiers: [], label: "通知中心 (F12)"),
        // ⌘⌥
        BlacklistEntry(keyCode: kVK_Escape, modifiers: [.maskCommand, .maskAlternate], label: "强制退出对话框 (⌘⌥Esc)"),
        BlacklistEntry(keyCode: kVK_ANSI_D, modifiers: [.maskCommand, .maskAlternate], label: "显示/隐藏 Dock (⌘⌥D)"),
        // ⌃ 单 modifier — Spaces 切换
        BlacklistEntry(keyCode: kVK_LeftArrow, modifiers: .maskControl, label: "上一个 Space (⌃←)"),
        BlacklistEntry(keyCode: kVK_RightArrow, modifiers: .maskControl, label: "下一个 Space (⌃→)"),
        BlacklistEntry(keyCode: kVK_UpArrow, modifiers: .maskControl, label: "Mission Control (⌃↑)"),
        BlacklistEntry(keyCode: kVK_DownArrow, modifiers: .maskControl, label: "App Exposé (⌃↓)"),
    ]

    // MARK: - 内部冲突(F7=C)

    /// VoiceBee 自家 hotkey 之间的冲突类别
    enum InternalConflict {
        /// 跟另一个 VoiceBee hotkey 完全相同或超集/子集
        case sameAsOtherHotkey(name: String)
        /// main hotkey 使用的 modifier 跟当前 translation trigger 冲突
        case mainModifierConflictsWithTranslationTrigger(trigger: String)
    }

    /// 检测一个新的 main 录音 hotkey 是否跟其他已配置 hotkey 冲突.
    /// `existing` 是其他 hotkey 的 (name, hotkey) 列表(用于错误提示).
    static func internalConflict(
        candidate: Hotkey,
        existing: [(name: String, hotkey: Hotkey)]
    ) -> InternalConflict? {
        for entry in existing {
            if hotkeyOverlap(candidate, entry.hotkey) {
                return .sameAsOtherHotkey(name: entry.name)
            }
        }
        return nil
    }

    /// F7=C 重叠判定:两个 hotkey 在事件流上是否会"互相干扰".
    /// 规则:
    /// - modifierOnly(M1) vs modifierOnly(M2) → M1 == M2
    /// - modifierOnly(M) vs combo(_, mods, _) → mods 仅含 M.flagMask(combo 用了 M 作为唯一 modifier)
    /// - combo(kc1, mods1) vs combo(kc2, mods2) → kc1 == kc2 AND (mods1 ⊆ mods2 OR mods2 ⊆ mods1)
    static func hotkeyOverlap(_ a: Hotkey, _ b: Hotkey) -> Bool {
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl, .maskSecondaryFn]
        switch (a, b) {
        case (.modifierOnly(let m1, _), .modifierOnly(let m2, _)):
            return m1 == m2
        case (.modifierOnly(let m, _), .combo(_, let mods, _)),
             (.combo(_, let mods, _), .modifierOnly(let m, _)):
            // 用户按住 M → modifierOnly 触发;若 M 是 combo 的唯一 modifier,combo 永远等不到自己的 keyDown
            return mods.intersection(relevant) == m.flagMask
        case (.combo(let kc1, let mods1, _), .combo(let kc2, let mods2, _)):
            guard kc1 == kc2 else { return false }
            let m1 = mods1.intersection(relevant)
            let m2 = mods2.intersection(relevant)
            return m1 == m2 || m1.isSubset(of: m2) || m2.isSubset(of: m1)
        }
    }

    /// main 录音 hotkey 的 modifier 跟 translation trigger 是否冲突(沿用 TranslationSettings 逻辑).
    /// 注意:这是个独立检查,不归 internalConflict 主路径(因 trigger 不是 Hotkey 类型).
    static func mainConflictsWithTrigger(main: Hotkey, triggerMask: CGEventFlags?) -> Bool {
        guard let trigger = triggerMask else { return false }
        // main hotkey 占用的 modifier 跟 trigger 重叠 → 用户按 main 进入录音的瞬间也会触发 trigger
        return !main.modifierMask.intersection(trigger).isEmpty
    }
}
