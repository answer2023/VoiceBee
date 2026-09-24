import SwiftUI

/// 隐私政策完整版(网站页,可独立于发版更新)
enum PrivacyPolicy {
    static let url = URL(string: "https://jotbee.app/privacy.html")!
}

/// 隐私要点列表 — 设置页与首启引导共用,措辞须与网站隐私政策保持一致
struct PrivacySummaryList: View {
    private let items: [(icon: String, title: String, detail: String)] = [
        ("lock.shield", "可选完全本地",
         "选用 WhisperKit 识别 + 本地 Ollama 润色时，语音和文字全程不离开这台 Mac。"),
        ("waveform", "Apple 语音识别（默认引擎）",
         "调用 macOS 系统服务，音频可能被发送到 Apple 服务器处理，受 Apple 隐私政策约束。"),
        ("sparkles", "AI 润色 / 翻译",
         "待处理文字、常用语言和词典专名会发送到你配置的 AI 服务（本地 Ollama 除外），使用你自己的 API 密钥直连，VoiceBee 不中转、不留副本。"),
        ("internaldrive", "数据只存本机",
         "API 密钥存于钥匙串；历史记录（最近 50 条）、词典、使用统计仅保存在本机。"),
        ("hand.raised", "我们不做的事",
         "VoiceBee 没有服务器：不收集数据、无广告、无追踪、无需账号。")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(items, id: \.title) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(.tint)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.system(size: 13, weight: .medium))
                        Text(item.detail)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// 设置 → 隐私
struct PrivacySettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("隐私")
                    .font(.system(size: 20, weight: .semibold))

                Text("VoiceBee 的语音识别和 AI 处理都支持完全本地运行。是否联网、用哪个引擎，由你在设置中决定。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                SettingsSection(title: "数据去向", description: "") {
                    PrivacySummaryList()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button("查看完整隐私政策") {
                    NSWorkspace.shared.open(PrivacyPolicy.url)
                }
                .controlSize(.small)
            }
            .padding(24)
        }
    }
}
