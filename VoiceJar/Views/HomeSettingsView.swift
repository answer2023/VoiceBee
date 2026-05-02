import SwiftUI

/// 主页 — 累计使用统计
struct HomeSettingsView: View {
    @Bindable var appState: AppState
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("主页")
                    .font(.system(size: 20, weight: .semibold))

                Text("VoiceBee 帮你节省了多少打字时间")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // 节省时间高亮卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.badge.checkmark")
                            .font(.system(size: 14))
                            .foregroundStyle(.green)
                        Text("已节省时间")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text(DurationFormat.compact(seconds: appState.stats.timeSavedSeconds))
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text("基于手打 60 字/分钟基准估算")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                // 统计指标网格
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    StatTile(
                        icon: "mic.fill",
                        label: "累计调用",
                        value: "\(appState.stats.totalRecords)",
                        unit: "次",
                        tint: .blue
                    )
                    StatTile(
                        icon: "text.alignleft",
                        label: "累计字数",
                        value: formatNumber(appState.stats.totalChars),
                        unit: "字",
                        tint: .purple
                    )
                    StatTile(
                        icon: "waveform",
                        label: "录音时长",
                        value: DurationFormat.compact(seconds: appState.stats.totalSeconds),
                        unit: "",
                        tint: .orange
                    )
                    StatTile(
                        icon: "speedometer",
                        label: "平均速度",
                        value: appState.stats.charsPerMinute > 0
                            ? String(format: "%.0f", appState.stats.charsPerMinute)
                            : "—",
                        unit: "字/分",
                        tint: .pink
                    )
                }

                // 词典参与度
                if !appState.vocab.entries.isEmpty {
                    SettingsSection(title: "词典参与", description: "命中次数最多的词条") {
                        let top = appState.vocab.entries
                            .filter { $0.hitCount > 0 }
                            .sorted { $0.hitCount > $1.hitCount }
                            .prefix(5)
                        if top.isEmpty {
                            Text("还没有命中记录")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(Array(top), id: \.id) { entry in
                                    HStack {
                                        Text(entry.term)
                                            .font(.system(size: 12, weight: .medium))
                                        if !entry.category.isEmpty {
                                            Text(entry.category)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text("\(entry.hitCount)")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                            }
                        }
                    }
                }

                // 起始时间
                if let firstUsed = appState.stats.firstUsedAt {
                    HStack {
                        Image(systemName: "calendar")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Text("从 \(firstUsed, format: .dateTime.year().month().day()) 开始使用")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer()
                        Button("重置统计") { showResetConfirm = true }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }

                Spacer()
            }
            .padding(24)
        }
        .confirmationDialog(
            "确定要重置所有统计数据吗？",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("重置", role: .destructive) { appState.stats.reset() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("累计调用、字数、时长都将归零，词典命中次数不受影响。")
        }
    }

    private func formatNumber(_ n: Int) -> String {
        if n >= 10_000 {
            return String(format: "%.1fw", Double(n) / 10_000)
        }
        return "\(n)"
    }
}

/// 统计指标卡片
private struct StatTile: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
