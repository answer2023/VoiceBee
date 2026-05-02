import AppKit
import SwiftUI

/// 实时语音输入浮窗 — 跟随光标位置，圆角气泡样式
@MainActor
class OverlayWindow {
    private var window: NSPanel?
    private var hostingView: NSHostingView<OverlayContentView>?
    private var contentModel = OverlayContentModel()

    func show() {
        if window == nil {
            createWindow()
        }
        positionNearCaret()
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    func updateText(_ text: String) {
        contentModel.text = text.isEmpty ? "正在聆听…" : text
        contentModel.isPlaceholder = text.isEmpty
        contentModel.state = .recording
        resizeAndReposition()
    }

    func showProcessing() {
        contentModel.state = .processing
    }

    /// 更新润色中的文本（保持 processing 状态 + 橙色指示灯）
    func updateProcessingText(_ text: String) {
        contentModel.text = text
        contentModel.isPlaceholder = false
        resizeAndReposition()
    }

    func showDone() {
        contentModel.state = .done
    }

    func setStructured(_ structured: Bool) {
        contentModel.isStructured = structured
    }

    func showTranslating() {
        contentModel.state = .translating
        contentModel.text = "翻译中…"
        contentModel.isPlaceholder = true
        resizeAndReposition()
    }

    /// 显示 / 隐藏「正在翻译」标记药丸（OpenLess 风格，主胶囊上方）
    func showTranslationBadge(_ shown: Bool) {
        contentModel.translateBadge = shown
        resizeAndReposition()
    }

    func showTranslated(_ text: String) {
        contentModel.state = .translated
        contentModel.text = text
        contentModel.isPlaceholder = false
        resizeAndReposition()
    }

    private func createWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.becomesKeyOnlyIfNeeded = true  // 不抢焦点
        panel.hidesOnDeactivate = false

        // contentView 也必须透明，否则直角背景会遮住 SwiftUI 圆角
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = .clear

        let hosting = NSHostingView(rootView: OverlayContentView(model: contentModel))
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.layer?.backgroundColor = .clear
        panel.contentView?.addSubview(hosting)
        hostingView = hosting

        window = panel
    }

    /// 获取当前输入光标位置，定位浮窗
    private func positionNearCaret() {
        guard let window else { return }

        var caretPoint: NSPoint?

        // 尝试通过 Accessibility API 获取光标位置
        let systemWide = AXUIElementCreateSystemWide()
        var focusedElement: AnyObject?
        if AXUIElementCopyAttributeValue(systemWide, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success {
            // AX API 成功时保证返回正确的 CF 类型
            let axElement = focusedElement as! AXUIElement
            var positionValue: AnyObject?
            if AXUIElementCopyAttributeValue(axElement, kAXSelectedTextRangeAttribute as CFString, &positionValue) == .success {
                var boundsValue: AnyObject?
                if AXUIElementCopyParameterizedAttributeValue(
                    axElement,
                    kAXBoundsForRangeParameterizedAttribute as CFString,
                    positionValue!,
                    &boundsValue
                ) == .success {
                    let axValue = boundsValue as! AXValue
                    var rect = CGRect.zero
                    if AXValueGetValue(axValue, .cgRect, &rect) {
                        // AX 坐标是屏幕坐标（左上角为原点），转换为 AppKit 坐标（左下角为原点）
                        if let screen = NSScreen.main {
                            let screenHeight = screen.frame.height
                            caretPoint = NSPoint(
                                x: rect.origin.x,
                                y: screenHeight - rect.origin.y - rect.height - 50 // 在光标下方50pt
                            )
                        }
                    }
                }
            }
        }

        // fallback: 如果拿不到光标位置，用鼠标位置
        if caretPoint == nil {
            let mouseLocation = NSEvent.mouseLocation
            caretPoint = NSPoint(x: mouseLocation.x - 20, y: mouseLocation.y - 60)
        }

        if let point = caretPoint {
            // 确保不超出屏幕
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                let x = min(max(point.x, screenFrame.minX + 10), screenFrame.maxX - window.frame.width - 10)
                let y = min(max(point.y, screenFrame.minY + 10), screenFrame.maxY - window.frame.height - 10)
                window.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                window.setFrameOrigin(point)
            }
        }
    }

    private func resizeAndReposition() {
        guard let window else { return }
        let text = contentModel.text
        let font = NSFont.systemFont(ofSize: 14)
        let maxWidth: CGFloat = 500
        let size = (text as NSString).boundingRect(
            with: NSSize(width: maxWidth - 50, height: 160),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        )
        let newWidth = min(max(size.width + 56, 160), maxWidth)
        var extraHeight: CGFloat = contentModel.state == .translated ? 20 : 0
        if contentModel.translateBadge { extraHeight += 26 }  // 翻译药丸高度
        let newHeight = min(max(size.height + 24 + extraHeight, 44), 160)

        var frame = window.frame
        frame.size.width = newWidth
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - SwiftUI 浮窗内容

@Observable
class OverlayContentModel {
    var text: String = "正在聆听…"
    var isPlaceholder: Bool = true
    var state: OverlayState = .recording
    var isStructured: Bool = false
    var translateBadge: Bool = false  // 录音中按了触发键 → 蓝色药丸

    enum OverlayState {
        case recording, processing, done, translating, translated
    }
}

struct OverlayContentView: View {
    @Bindable var model: OverlayContentModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 翻译标记药丸（OpenLess 风格，主胶囊上方）
            if model.translateBadge {
                HStack(spacing: 5) {
                    Circle()
                        .fill(.blue)
                        .frame(width: 6, height: 6)
                    Text("正在翻译")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.blue)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.14), in: Capsule())
            }

            // 主胶囊
            HStack(spacing: 10) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                    .shadow(color: dotColor.opacity(0.6), radius: 3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.text)
                        .font(.system(size: 14))
                        .foregroundStyle(model.isPlaceholder ? .secondary : .primary)
                        .lineLimit(model.state == .translated ? 5 : 3)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.state == .translated {
                        Text("已复制到剪贴板")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(0.2), lineWidth: 0.5)
                    }
            }
        }
    }

    private var dotColor: Color {
        switch model.state {
        case .recording: return model.isStructured ? .purple : .red
        case .processing: return .orange
        case .done: return .green
        case .translating: return .blue
        case .translated: return .cyan
        }
    }
}
