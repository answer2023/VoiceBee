import SwiftUI

/// 历史记录面板
struct HistoryView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            // 标题栏
            HStack {
                Text("语音历史")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if !appState.history.isEmpty {
                    Button("清空") {
                        appState.history.removeAll()
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if appState.history.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 32))
                        .foregroundStyle(.quaternary)
                    Text("暂无记录")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text("按住 \(appState.hotkey.displayName) 说话后记录会出现在这里")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(appState.history) { record in
                            HistoryRow(record: record)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 420, height: 480)
    }
}

/// 单条历史记录行
struct HistoryRow: View {
    let record: TranscriptionRecord
    @State private var isHovering = false
    @State private var showCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 时间和时长
            HStack {
                Text(record.timestamp, style: .time)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text("\(String(format: "%.1f", record.duration))秒")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)

                Spacer()

                if isHovering {
                    HStack(spacing: 8) {
                        // 复制按钮
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(record.polishedText, forType: .string)
                            withAnimation { showCopied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopied = false }
                            }
                        } label: {
                            Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11))
                                .foregroundStyle(showCopied ? .green : .secondary)
                        }
                        .buttonStyle(.plain)
                        .help("复制")

                        // 重新上屏按钮
                        Button {
                            TextInjector.inject(record.polishedText)
                        } label: {
                            Image(systemName: "text.insert")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重新输入到光标位置")
                    }
                }
            }

            // 润色后文本
            Text(record.polishedText)
                .font(.system(size: 13))
                .lineLimit(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 如果原文和润色后不同，显示原文
            if record.rawText != record.polishedText {
                Text(record.rawText)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color(.controlBackgroundColor) : .clear)
        .onHover { isHovering = $0 }
    }
}
