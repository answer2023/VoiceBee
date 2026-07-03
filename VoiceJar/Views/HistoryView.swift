import SwiftUI

/// 历史记录面板
struct HistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var polishingIds: Set<UUID> = []
    @State private var rowErrors: [UUID: String] = [:]
    private let polishService = PolishService()

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
                            HistoryRow(
                                record: record,
                                isPolishing: polishingIds.contains(record.id),
                                errorText: rowErrors[record.id],
                                onRePolish: { rePolish(record) },
                                onInsert: { insert(record) }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(width: 420, height: 480)
    }

    private func rePolish(_ record: TranscriptionRecord, style: OutputStyle? = nil) {
        let snapshot = appState.polishSettings.snapshot
        guard snapshot.engine != .none else { return }
        polishingIds.insert(record.id)
        rowErrors[record.id] = nil
        let vocabTerms = appState.vocab.activeTerms
        let activeStyle = style ?? appState.outputStyle.defaultStyle
        Task {
            defer {
                Task { @MainActor in polishingIds.remove(record.id) }
            }
            do {
                let polished = try await polishService.polish(
                    text: record.rawText,
                    settings: snapshot,
                    style: activeStyle,
                    vocabTerms: vocabTerms
                )
                await MainActor.run {
                    appState.updateHistory(id: record.id, polishedText: polished)
                    appState.vocab.recordHits(in: polished)
                }
            } catch {
                VJLog.log("❌ 重新润色失败: \(error)", prefix: "History")
                let message = "重新润色失败：\(error.localizedDescription)"
                await MainActor.run {
                    showRowError(record.id, message)
                }
            }
        }
    }

    private func insert(_ record: TranscriptionRecord) {
        if !TextInjector.inject(record.polishedText) {
            showRowError(record.id, "缺少辅助功能权限，文本已复制到剪贴板，可手动 ⌘V 粘贴")
        }
    }

    /// 行内瞬态错误提示 — 4 秒后自动消失(若期间未被新消息覆盖)
    private func showRowError(_ id: UUID, _ message: String) {
        rowErrors[id] = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if rowErrors[id] == message {
                rowErrors[id] = nil
            }
        }
    }
}

/// 单条历史记录行
struct HistoryRow: View {
    let record: TranscriptionRecord
    let isPolishing: Bool
    let errorText: String?
    let onRePolish: () -> Void
    let onInsert: () -> Void
    @State private var isHovering = false
    @State private var showCopied = false
    @State private var showCopiedRaw = false

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

                if isPolishing {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 14, height: 14)
                        Text("润色中…")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                } else if isHovering {
                    HStack(spacing: 8) {
                        // 复制润色版
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
                        .help("复制润色后")

                        // 复制原文（仅当原文与润色文不同）
                        if record.rawText != record.polishedText {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(record.rawText, forType: .string)
                                withAnimation { showCopiedRaw = true }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    withAnimation { showCopiedRaw = false }
                                }
                            } label: {
                                Image(systemName: showCopiedRaw ? "checkmark" : "doc.on.doc.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(showCopiedRaw ? .green : .secondary.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                            .help("复制原文")
                        }

                        // 重新润色
                        Button {
                            onRePolish()
                        } label: {
                            Image(systemName: "sparkles")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("重新润色（用当前 AI 引擎和模式）")

                        // 重新上屏
                        Button {
                            onInsert()
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

            // 瞬态错误提示（重新润色失败 / 无辅助功能权限）
            if let errorText {
                Text(errorText)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(isHovering ? Color(.controlBackgroundColor) : .clear)
        .onHover { isHovering = $0 }
    }
}
