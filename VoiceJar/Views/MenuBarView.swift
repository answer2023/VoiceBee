import SwiftUI

/// 菜单栏下拉视图
struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部状态区
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.2))
                        .frame(width: 28, height: 28)
                    Image(systemName: statusIcon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(statusColor)
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                    HStack(spacing: 4) {
                        Text("语音: \(appState.hotkey.displayName)")
                        Text("·")
                        Text("翻译: \(appState.translateHotkey.displayName)")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 8)

            // 最近转写结果
            if !appState.polishedText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("最近转写")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.polishedText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                    }

                    Text(appState.polishedText)
                        .font(.system(size: 12))
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().padding(.horizontal, 8)
            }

            // 最近翻译结果
            if !appState.translatedText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("最近翻译")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(appState.translatedText, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                    }

                    Text(appState.translatedText)
                        .font(.system(size: 12))
                        .lineLimit(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider().padding(.horizontal, 8)
            }

            // 错误信息
            if let error = appState.errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider().padding(.horizontal, 8)
            }

            // 底部操作栏
            HStack(spacing: 4) {
                MenuBarButton(icon: "gear", label: "设置") {
                    NotificationCenter.default.post(name: .openSettings, object: nil)
                }

                MenuBarButton(icon: "clock.arrow.circlepath", label: "历史") {
                    NotificationCenter.default.post(name: .openHistory, object: nil)
                }
                .opacity(appState.history.isEmpty ? 0.4 : 1)
                .disabled(appState.history.isEmpty)

                Spacer()

                MenuBarButton(icon: "power", label: "退出") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 280)
    }

    private var statusColor: Color {
        if appState.isPaused { return .gray }
        if appState.isRecording { return .red }
        if appState.isTranslating { return .blue }
        if appState.isProcessing { return .orange }
        return .green
    }

    private var statusIcon: String {
        if appState.isPaused { return "pause.fill" }
        if appState.isRecording { return "mic.fill" }
        if appState.isTranslating { return "character.book.closed" }
        if appState.isProcessing { return "waveform" }
        return "mic"
    }

    private var statusTitle: String {
        if appState.isPaused { return "已暂停" }
        if appState.isRecording { return "正在录音…" }
        if appState.isTranslating { return "翻译中…" }
        if appState.isProcessing { return "识别中…" }
        return "就绪"
    }
}

/// 菜单栏底部小按钮
struct MenuBarButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let hotkeyChanged = Notification.Name("VoiceJarHotkeyChanged")
    static let openSettings = Notification.Name("VoiceJarOpenSettings")
    static let openHistory = Notification.Name("VoiceJarOpenHistory")
    static let recognitionLanguageChanged = Notification.Name("VoiceJarRecognitionLanguageChanged")
    static let translateHotkeyChanged = Notification.Name("VoiceJarTranslateHotkeyChanged")
    static let repeatLastHotkeyChanged = Notification.Name("VoiceJarRepeatLastHotkeyChanged")
    static let pauseStateChanged = Notification.Name("VoiceJarPauseStateChanged")
}
