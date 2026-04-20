import SwiftUI
import Speech

/// 首次启动引导窗口
struct OnboardingView: View {
    @State private var accessibilityGranted = false
    @State private var microphoneGranted = false
    @State private var speechGranted = false
    @State private var checkTimer: Timer?
    var onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 顶部图标和标题
            VStack(spacing: 12) {
                Image(systemName: "mic.badge.waveform")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .padding(.top, 30)

                Text("欢迎使用 VoiceBee")
                    .font(.system(size: 22, weight: .bold))

                Text("按住 Fn 说话，松开即输入\n中文语音输入，快人一步")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.bottom, 24)

            // 权限列表
            VStack(spacing: 0) {
                Text("需要以下权限才能正常工作")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)

                VStack(spacing: 2) {
                    PermissionStepRow(
                        step: 1,
                        icon: "hand.raised.fill",
                        title: "辅助功能",
                        description: accessibilityGranted
                            ? "监听全局快捷键（Fn 按住说话）"
                            : "若已开启仍显示未授权，请关闭后重新打开",
                        isGranted: accessibilityGranted,
                        action: {
                            HotkeyManager.checkAccessibility(prompt: true)
                        }
                    )

                    PermissionStepRow(
                        step: 2,
                        icon: "mic.fill",
                        title: "麦克风",
                        description: "录制语音",
                        isGranted: microphoneGranted,
                        action: {
                            Task {
                                let granted = await requestMicrophone()
                                await MainActor.run { microphoneGranted = granted }
                            }
                        }
                    )

                    PermissionStepRow(
                        step: 3,
                        icon: "waveform",
                        title: "语音识别",
                        description: "将语音转为文字",
                        isGranted: speechGranted,
                        action: {
                            Task {
                                let status = await SpeechRecognizer.requestAuthorization()
                                await MainActor.run { speechGranted = (status == .authorized) }
                            }
                        }
                    )
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            // 底部按钮
            VStack(spacing: 10) {
                if allGranted {
                    Button {
                        onComplete()
                    } label: {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text("开始使用")
                        }
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Text("请完成以上权限授权")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    Button {
                        onComplete()
                    } label: {
                        Text("稍后设置")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 380, height: 480)
        .onAppear {
            startPolling()
            checkPermissions()
        }
        .onDisappear {
            checkTimer?.invalidate()
        }
    }

    private var allGranted: Bool {
        accessibilityGranted && microphoneGranted && speechGranted
    }

    private func checkPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        speechGranted = (speechStatus == .authorized)
    }

    private func startPolling() {
        checkTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            DispatchQueue.main.async {
                checkPermissions()
            }
        }
    }

    private func requestMicrophone() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }
}

/// 权限步骤行
struct PermissionStepRow: View {
    let step: Int
    let icon: String
    let title: String
    let description: String
    let isGranted: Bool
    let action: () -> Void

    var body: some View {
        Button(action: { if !isGranted { action() } }) {
            HStack(spacing: 12) {
                // 步骤编号或勾选
                ZStack {
                    Circle()
                        .fill(isGranted ? Color.green : Color.accentColor)
                        .frame(width: 26, height: 26)
                    if isGranted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(step)")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }

                // 图标
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(isGranted ? .green : .secondary)
                    .frame(width: 20)

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isGranted {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 16))
                } else {
                    Text("授权")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.blue.opacity(0.1), in: Capsule())
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isGranted ? Color.green.opacity(0.05) : Color(.controlBackgroundColor))
            )
        }
        .buttonStyle(.plain)
    }
}
