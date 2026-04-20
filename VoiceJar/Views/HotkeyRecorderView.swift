import AppKit
import Carbon.HIToolbox
import SwiftUI

/// 快捷键录制器 — 点击后按任意组合键录入
struct HotkeyRecorderView: View {
    @Binding var hotkey: HotkeyCombo
    var onChange: ((HotkeyCombo) -> Void)?

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
                HotkeyRecorderHelper(isRecording: $isRecording) { combo in
                    hotkey = combo
                    onChange?(combo)
                }
            }
        }
    }
}

/// NSView wrapper 用于捕获按键事件
private struct HotkeyRecorderHelper: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onRecord: (HotkeyCombo) -> Void

    func makeNSView(context: Context) -> HotkeyRecorderNSView {
        let view = HotkeyRecorderNSView()
        view.onRecord = { combo in
            onRecord(combo)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        // 自动获取焦点
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: HotkeyRecorderNSView, context: Context) {}
}

final class HotkeyRecorderNSView: NSView {
    var onRecord: ((HotkeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // Escape 取消
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        let keyCode = Int(event.keyCode)
        var modifiers = CGEventFlags()

        if event.modifierFlags.contains(.control) { modifiers.insert(.maskControl) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.maskAlternate) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.maskShift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.maskCommand) }
        if event.modifierFlags.contains(.function) { modifiers.insert(.maskSecondaryFn) }

        // 至少需要一个修饰键（防止普通字母被绑定）
        let hasModifier = !modifiers.isEmpty
        guard hasModifier else { return }

        let combo = HotkeyCombo(keyCode: keyCode, modifiers: modifiers)
        onRecord?(combo)
    }

    // 处理 Fn 单键
    override func flagsChanged(with event: NSEvent) {
        if event.modifierFlags.contains(.function) {
            let combo = HotkeyCombo.fn
            onRecord?(combo)
        }
    }
}
