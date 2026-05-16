import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 快捷键录制器 — 点击后按任意组合键录入(Phase 3-B 升级:支持 modifier-only).
///
/// 录入策略(F5=B):
/// - keyDown 含 modifier → 直接录入 combo
/// - flagsChanged(modifier 按下) → 启动 250ms 窗口
///   - 窗口内 keyDown 跟来 → 按 combo 录入(取消窗口)
///   - 窗口内 modifier 松开 → 按 modifier-only 录入(立即,UX 比等满 250ms 更响应)
///   - 250ms 满 → 按 modifier-only 录入
///
/// `acceptsModifierOnly` flag:供 caller 决定是否允许 modifier-only(translate / repeatLast 应禁用)
struct HotkeyRecorderView: View {
    /// 显示当前 hotkey(展示用,无 @Binding);提交走 onCommit 让 caller 拦截做冲突检查
    let hotkey: Hotkey
    /// 是否允许 modifier-only(默认 true).translate / repeatLast 应传 false.
    var acceptsModifierOnly: Bool = true
    /// 用户录入新 hotkey 时回调;caller 决定是否真的保存(F6 冲突拦截在 caller 做).
    /// 传入的 candidate.mode = .hold(占位),caller 应保留原 mode.
    let onCommit: (Hotkey) -> Void

    @State private var isRecording = false

    var body: some View {
        Button {
            isRecording = true
        } label: {
            HStack(spacing: 4) {
                if isRecording {
                    Image(systemName: "record.circle")
                        .foregroundStyle(.red)
                    Text("按下快捷键…")
                        .foregroundStyle(.secondary)
                } else {
                    Text(hotkey.displayName)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.red.opacity(0.1) : Color.secondary.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.red : Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .background {
            if isRecording {
                HotkeyRecorderHelper(isRecording: $isRecording, acceptsModifierOnly: acceptsModifierOnly) { combo in
                    onCommit(combo)
                }
            }
        }
    }
}

/// NSView wrapper 用于捕获按键事件
private struct HotkeyRecorderHelper: NSViewRepresentable {
    @Binding var isRecording: Bool
    var acceptsModifierOnly: Bool
    var onRecord: (Hotkey) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.acceptsModifierOnly = acceptsModifierOnly
        view.onRecord = { combo in
            onRecord(combo)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {}
}

final class HotkeyRecorderNSView: NSView {
    var onRecord: ((Hotkey) -> Void)?
    var onCancel: (() -> Void)?
    var acceptsModifierOnly: Bool = true

    /// 待 commit 的 modifier-only — 250ms 窗口内若有 keyDown,清掉走 combo 路径
    private var pendingModifierKey: ModifierKey?
    private var pendingTimer: DispatchWorkItem?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Escape 取消
        if event.keyCode == UInt16(kVK_Escape) {
            cancelPending()
            onCancel?()
            return
        }

        // 在 modifier-only 250ms 窗口内 — keyDown 表明用户在录 combo,清掉 pending
        cancelPending()

        let keyCode = Int(event.keyCode)
        var modifiers = CGEventFlags()
        if event.modifierFlags.contains(.control) { modifiers.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.maskAlternate) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.maskShift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.maskCommand) }
        if event.modifierFlags.contains(.function) { modifiers.insert(.maskSecondaryFn) }

        // 至少需要一个 modifier(否则是裸字母,不让绑定)
        guard !modifiers.isEmpty else { return }

        let combo = Hotkey.combo(keyCode: keyCode, modifiers: modifiers, mode: .hold)
        onRecord?(combo)
    }

    override func flagsChanged(with event: NSEvent) {
        guard acceptsModifierOnly else { return }
        let physicalKeyCode = Int(event.keyCode)
        guard let mk = ModifierKey.from(physicalKeyCode: physicalKeyCode) else { return }

        let isPressed = event.modifierFlags.contains(mk.cocoaMaskForRecorder)
        if isPressed {
            // 启动 250ms 窗口
            cancelPending()
            pendingModifierKey = mk
            let work = DispatchWorkItem { [weak self] in
                guard let self, let pending = self.pendingModifierKey else { return }
                self.pendingModifierKey = nil
                self.pendingTimer = nil
                self.onRecord?(.modifierOnly(pending, mode: .hold))
            }
            pendingTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        } else {
            // 同一个 modifier 松开 — 用户在 250ms 内已经松开,提前 commit 提高响应感
            if let pending = pendingModifierKey, pending == mk {
                pendingTimer?.cancel()
                pendingTimer = nil
                pendingModifierKey = nil
                onRecord?(.modifierOnly(pending, mode: .hold))
            }
        }
    }

    private func cancelPending() {
        pendingTimer?.cancel()
        pendingTimer = nil
        pendingModifierKey = nil
    }
}

// MARK: - NSEvent.ModifierFlags <-> ModifierKey 映射(仅在 recorder 用)

private extension ModifierKey {
    var cocoaMaskForRecorder: NSEvent.ModifierFlags {
        switch self {
        case .fn: return .function
        case .leftCommand, .rightCommand: return .command
        case .leftShift, .rightShift: return .shift
        case .leftOption, .rightOption: return .option
        case .leftControl, .rightControl: return .control
        }
    }
}
