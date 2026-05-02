import SwiftUI

/// 词典设置 — 用户专名 / 术语管理 + 自学习候选词
struct VocabSettingsView: View {
    @Bindable var appState: AppState
    @State private var newTerm: String = ""
    @State private var newCategory: String = ""
    @State private var editingId: UUID?
    @State private var editingTerm: String = ""
    @State private var editingCategory: String = ""

    private var candidates: [String] {
        VocabStore.mineCandidates(
            from: appState.history,
            existing: appState.vocab.existingTermSet
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("词典")
                    .font(.system(size: 20, weight: .semibold))

                Text("专有名词、产品名、人名 — 启用的词条会作为热词注入语音识别，并提示给润色模型按上下文判断是否替换。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                // 自学习候选
                if !candidates.isEmpty {
                    SettingsSection(
                        title: "候选词",
                        description: "从历史记录中挖掘的高频专名，点击即可加入词典"
                    ) {
                        FlowLayout(spacing: 6) {
                            ForEach(candidates, id: \.self) { word in
                                Button {
                                    appState.vocab.add(VocabEntry(term: word, category: "自学习"))
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "plus.circle")
                                            .font(.system(size: 11))
                                        Text(word)
                                            .font(.system(size: 12))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(.blue.opacity(0.1), in: Capsule())
                                    .foregroundStyle(.blue)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                // 新增词条
                SettingsSection(title: "新增词条", description: "") {
                    HStack(spacing: 8) {
                        TextField("Claude / ChatGPT / 张三 …", text: $newTerm)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                        TextField("分类（可选）", text: $newCategory)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .frame(width: 100)
                        Button("添加") {
                            let trimmed = newTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return }
                            appState.vocab.add(VocabEntry(
                                term: trimmed,
                                category: newCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                            ))
                            newTerm = ""
                            newCategory = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                // 词条列表
                SettingsSection(
                    title: "我的词典 (\(appState.vocab.entries.count))",
                    description: ""
                ) {
                    if appState.vocab.entries.isEmpty {
                        Text("暂无词条")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 6) {
                            ForEach(appState.vocab.entries) { entry in
                                VocabRow(
                                    entry: entry,
                                    isEditing: editingId == entry.id,
                                    editingTerm: $editingTerm,
                                    editingCategory: $editingCategory,
                                    onStartEdit: {
                                        editingId = entry.id
                                        editingTerm = entry.term
                                        editingCategory = entry.category
                                    },
                                    onCommit: {
                                        var updated = entry
                                        updated.term = editingTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                                        updated.category = editingCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                                        if !updated.term.isEmpty {
                                            appState.vocab.update(updated)
                                        }
                                        editingId = nil
                                    },
                                    onCancel: { editingId = nil },
                                    onToggle: { appState.vocab.toggle(entry.id) },
                                    onDelete: {
                                        if editingId == entry.id { editingId = nil }
                                        appState.vocab.remove(entry.id)
                                    }
                                )
                            }
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
        }
    }
}

/// 单条词典行
private struct VocabRow: View {
    let entry: VocabEntry
    let isEditing: Bool
    @Binding var editingTerm: String
    @Binding var editingCategory: String
    let onStartEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { entry.enabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            if isEditing {
                TextField("词条", text: $editingTerm)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .onSubmit(onCommit)
                TextField("分类", text: $editingCategory)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .frame(width: 90)
                    .onSubmit(onCommit)
                Button("✓", action: onCommit)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                Button("×", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Text(entry.term)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(entry.enabled ? .primary : .tertiary)

                if !entry.category.isEmpty {
                    Text(entry.category)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.secondary.opacity(0.15), in: Capsule())
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if entry.hitCount > 0 {
                    Text("命中 \(entry.hitCount)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }

                if isHovering {
                    Button {
                        onStartEdit()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("编辑")

                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.red.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .help("删除")
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(isHovering && !isEditing ? Color(.controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
    }
}

/// 流式横向布局 — 候选词标签自动换行
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var height: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        height += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
