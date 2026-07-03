import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 词典设置 — 用户专名 / 术语管理 + 自学习候选词
struct VocabSettingsView: View {
    @Bindable var appState: AppState
    @State private var newTerm: String = ""
    @State private var newCategory: String = ""
    @State private var editingId: UUID?
    @State private var editingTerm: String = ""
    @State private var editingCategory: String = ""
    @State private var editingAliases: String = ""
    @State private var showImport = false
    @State private var selectedIds: Set<UUID> = []
    @State private var filter: VocabFilter = .all
    @State private var showDeleteConfirm = false
    @State private var exportError: String?
    // 派生数据缓存 — 词条可达数千(批量导入 Rime 词典),body 每次求值都全量扫描会卡顿,
    // 只在 entries / filter / history 变化时重算
    @State private var displayedEntries: [VocabEntry] = []
    @State private var filterCounts = FilterCounts()
    @State private var candidates: [String] = []

    enum VocabFilter: String, CaseIterable {
        case all = "全部"
        case enabled = "启用"
        case disabled = "禁用"
        case suspect = "可疑"
        case hit = "命中过"
    }

    private struct FilterCounts {
        var all = 0
        var enabled = 0
        var disabled = 0
        var suspect = 0
        var hit = 0
    }

    private func recomputeEntryDerived() {
        let all = appState.vocab.entries
        var counts = FilterCounts()
        counts.all = all.count
        for entry in all {
            if entry.enabled { counts.enabled += 1 } else { counts.disabled += 1 }
            if VocabStore.isSuspect(entry.term) { counts.suspect += 1 }
            if entry.hitCount > 0 { counts.hit += 1 }
        }
        filterCounts = counts
        recomputeDisplayed()
    }

    private func recomputeDisplayed() {
        let all = appState.vocab.entries
        switch filter {
        case .all: displayedEntries = all
        case .enabled: displayedEntries = all.filter { $0.enabled }
        case .disabled: displayedEntries = all.filter { !$0.enabled }
        case .suspect: displayedEntries = all.filter { VocabStore.isSuspect($0.term) }
        case .hit: displayedEntries = all.filter { $0.hitCount > 0 }
        }
    }

    private func recomputeCandidates() {
        candidates = VocabStore.mineCandidates(
            from: appState.history,
            existing: appState.vocab.existingTermSet
        )
    }

    private var displayedIds: Set<UUID> { Set(displayedEntries.map(\.id)) }
    private var allDisplayedSelected: Bool {
        !displayedEntries.isEmpty && displayedEntries.allSatisfy { selectedIds.contains($0.id) }
    }

    private var vocabListTitle: String {
        let total = appState.vocab.entries.count
        let shown = displayedEntries.count
        if filter == .all || total == shown {
            return "我的词典 (\(total))"
        }
        return "我的词典 (\(shown) / \(total))"
    }

    private func exportVocab() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json, .commaSeparatedText]
        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        panel.nameFieldStringValue = "voicebee-vocab-\(date).json"
        panel.message = "选择保存位置 — 扩展名 .json 保留全部字段，.csv 适合外部编辑"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content: String
            if url.pathExtension.lowercased() == "csv" {
                content = appState.vocab.exportCSV()
            } else {
                content = try appState.vocab.exportJSON()
            }
            try content.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            VJLog.log("❌ 导出失败: \(error)", prefix: "Vocab")
            exportError = "❌ 导出失败：\(error.localizedDescription)"
        }
    }

    private func filterLabel(_ f: VocabFilter) -> String {
        let count: Int
        switch f {
        case .all: count = filterCounts.all
        case .enabled: count = filterCounts.enabled
        case .disabled: count = filterCounts.disabled
        case .suspect: count = filterCounts.suspect
        case .hit: count = filterCounts.hit
        }
        return "\(f.rawValue) \(count)"
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
                    VStack(spacing: 8) {
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
                        HStack(spacing: 12) {
                            Button {
                                showImport = true
                            } label: {
                                Label("批量导入…", systemImage: "square.and.arrow.down")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)

                            Button {
                                exportVocab()
                            } label: {
                                Label("导出…", systemImage: "square.and.arrow.up")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                            .disabled(appState.vocab.entries.isEmpty)

                            if let exportError {
                                Text(exportError)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()
                        }
                    }
                }

                // 词条列表
                SettingsSection(
                    title: vocabListTitle,
                    description: ""
                ) {
                    if appState.vocab.entries.isEmpty {
                        Text("暂无词条")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        VStack(spacing: 8) {
                            // 过滤器
                            HStack(spacing: 6) {
                                ForEach(VocabFilter.allCases, id: \.self) { f in
                                    Button {
                                        filter = f
                                    } label: {
                                        Text(filterLabel(f))
                                            .font(.system(size: 11, weight: filter == f ? .medium : .regular))
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 3)
                                            .background(
                                                filter == f
                                                    ? Color.blue.opacity(0.15)
                                                    : Color.secondary.opacity(0.08),
                                                in: Capsule()
                                            )
                                            .foregroundStyle(filter == f ? .blue : .secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                            }

                            // 批量操作工具栏
                            if !selectedIds.isEmpty {
                                HStack(spacing: 8) {
                                    Text("已选 \(selectedIds.count) 个")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(.blue)
                                    Spacer()
                                    Button("启用") {
                                        appState.vocab.setEnabledBatch(selectedIds, enabled: true)
                                    }
                                    .controlSize(.mini)
                                    Button("禁用") {
                                        appState.vocab.setEnabledBatch(selectedIds, enabled: false)
                                    }
                                    .controlSize(.mini)
                                    Button("删除") {
                                        showDeleteConfirm = true
                                    }
                                    .controlSize(.mini)
                                    .tint(.red)
                                    Button("清除选中") {
                                        selectedIds.removeAll()
                                    }
                                    .controlSize(.mini)
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 11))
                                }
                                .padding(8)
                                .background(.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            }

                            // 全选 / 全不选
                            HStack {
                                Button {
                                    if allDisplayedSelected {
                                        selectedIds.subtract(displayedIds)
                                    } else {
                                        selectedIds.formUnion(displayedIds)
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: allDisplayedSelected ? "checkmark.square.fill" : "square")
                                            .font(.system(size: 11))
                                        Text(allDisplayedSelected ? "取消全选" : "全选当前列表")
                                            .font(.system(size: 11))
                                    }
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                Spacer()
                            }

                            // 列表
                            if displayedEntries.isEmpty {
                                Text("（当前过滤无词条）")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 12)
                            } else {
                                LazyVStack(spacing: 4) {
                                    ForEach(displayedEntries) { entry in
                                        VocabRow(
                                            entry: entry,
                                            isEditing: editingId == entry.id,
                                            isSelected: selectedIds.contains(entry.id),
                                            editingTerm: $editingTerm,
                                            editingCategory: $editingCategory,
                                            editingAliases: $editingAliases,
                                            onStartEdit: {
                                                editingId = entry.id
                                                editingTerm = entry.term
                                                editingCategory = entry.category
                                                // Phase 3-A:进入编辑态时把已有 aliases 平铺为逗号分隔字符串
                                                editingAliases = entry.aliases.joined(separator: ", ")
                                            },
                                            onCommit: {
                                                var updated = entry
                                                updated.term = editingTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                                                updated.category = editingCategory.trimmingCharacters(in: .whitespacesAndNewlines)
                                                // Phase 3-A:拆 aliases — 逗号或换行分隔,trim 空白,去空,保留顺序,去重
                                                let raw = editingAliases.split(whereSeparator: { $0 == "," || $0 == "\n" })
                                                var seen: Set<String> = []
                                                let parsed: [String] = raw.compactMap { piece in
                                                    let s = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    guard !s.isEmpty else { return nil }
                                                    let key = s.lowercased()
                                                    if seen.contains(key) { return nil }
                                                    seen.insert(key)
                                                    return s
                                                }
                                                updated.aliases = parsed
                                                if !updated.term.isEmpty {
                                                    appState.vocab.update(updated)
                                                }
                                                editingId = nil
                                            },
                                            onCancel: { editingId = nil },
                                            onToggle: { appState.vocab.toggle(entry.id) },
                                            onDelete: {
                                                if editingId == entry.id { editingId = nil }
                                                selectedIds.remove(entry.id)
                                                appState.vocab.remove(entry.id)
                                            },
                                            onToggleSelect: {
                                                if selectedIds.contains(entry.id) {
                                                    selectedIds.remove(entry.id)
                                                } else {
                                                    selectedIds.insert(entry.id)
                                                }
                                            }
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
                .confirmationDialog(
                    "删除选中的 \(selectedIds.count) 个词条？",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        appState.vocab.removeBatch(selectedIds)
                        selectedIds.removeAll()
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("此操作不可撤销。")
                }

                Spacer()
            }
            .padding(24)
        }
        .onChange(of: appState.vocab.entries, initial: true) {
            recomputeEntryDerived()
            recomputeCandidates()
        }
        .onChange(of: filter) {
            recomputeDisplayed()
        }
        .onChange(of: appState.history) {
            recomputeCandidates()
        }
        .sheet(isPresented: $showImport) {
            VocabImportSheet(vocab: appState.vocab, isPresented: $showImport)
        }
    }
}

/// 批量导入 sheet
private struct VocabImportSheet: View {
    let vocab: VocabStore
    @Binding var isPresented: Bool
    @State private var inputText: String = ""
    @State private var resultMessage: String?
    @State private var includeSuspect: Bool = false
    @State private var showSuspectList: Bool = false
    // 解析结果缓存 — Rime 词典可达 10^4-10^5 行,不能每次 body 求值都全量 parse,
    // 只在 inputText 变化后 debounce 一次解析 + 单遍分拣 clean / suspect
    @State private var cleanEntries: [VocabEntry] = []
    @State private var suspectEntries: [VocabEntry] = []
    @State private var parseTask: Task<Void, Never>?

    private var parsedCount: Int { cleanEntries.count + suspectEntries.count }
    private var importCount: Int { includeSuspect ? parsedCount : cleanEntries.count }

    private var entriesToImport: [VocabEntry] {
        includeSuspect ? cleanEntries + suspectEntries : cleanEntries
    }

    private func reparse(_ text: String) {
        var clean: [VocabEntry] = []
        var suspect: [VocabEntry] = []
        for entry in VocabStore.parseImport(text) {
            if VocabStore.isSuspect(entry.term) {
                suspect.append(entry)
            } else {
                clean.append(entry)
            }
        }
        cleanEntries = clean
        suspectEntries = suspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("批量导入词典")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button("关闭") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("支持 Rime 词典（.yaml）/ CSV / 纯文本。一行一个词条。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("• 用 `,` / `|` 分隔，第二段作分类；用 Tab 分隔（Rime 格式）只取第一列\n• `#` 开头作注释；`---` 之间的 YAML frontmatter 自动跳过\n• URL / 邮箱 / 含空格的句子默认过滤（不适合作语音热词）")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $inputText)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 220)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.secondary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Button {
                    pickFile()
                } label: {
                    Label("从文件…", systemImage: "doc.badge.plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string) {
                        inputText = inputText.isEmpty ? pasted : inputText + "\n" + pasted
                    }
                } label: {
                    Label("粘贴剪贴板", systemImage: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()

                Button("导入 \(importCount) 个") {
                    let result = vocab.addBatch(entriesToImport)
                    resultMessage = "✅ 新增 \(result.added) 个，跳过 \(result.skipped) 个重复"
                    if result.added > 0 {
                        inputText = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(importCount == 0)
            }

            // 解析摘要 + 可疑条目处理
            if parsedCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("解析到 \(parsedCount) 个，可用 \(cleanEntries.count) 个")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        if !suspectEntries.isEmpty {
                            Text("· \(suspectEntries.count) 个可疑")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                            Button(showSuspectList ? "收起" : "查看") {
                                showSuspectList.toggle()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(.blue)
                        }
                        Spacer()
                        if !suspectEntries.isEmpty {
                            Toggle("一并导入可疑条目", isOn: $includeSuspect)
                                .toggleStyle(.checkbox)
                                .controlSize(.mini)
                                .font(.system(size: 11))
                        }
                    }
                    if showSuspectList && !suspectEntries.isEmpty {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(Array(suspectEntries.prefix(50)), id: \.term) { entry in
                                    Text(entry.term)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                if suspectEntries.count > 50 {
                                    Text("…还有 \(suspectEntries.count - 50) 条")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 80)
                        .padding(8)
                        .background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
            }

            if let message = resultMessage {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        }
        .padding(20)
        .frame(width: 520, height: 480)
        .onChange(of: inputText) { _, newText in
            parseTask?.cancel()
            parseTask = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                reparse(newText)
            }
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        var types: [UTType] = [.text, .plainText, .commaSeparatedText]
        if let yaml = UTType(filenameExtension: "yaml") { types.append(yaml) }
        if let yml = UTType(filenameExtension: "yml") { types.append(yml) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            inputText = inputText.isEmpty ? content : inputText + "\n" + content
        } catch {
            resultMessage = "❌ 读取失败：\(error.localizedDescription)"
        }
    }
}

/// 单条词典行
private struct VocabRow: View {
    let entry: VocabEntry
    let isEditing: Bool
    let isSelected: Bool
    @Binding var editingTerm: String
    @Binding var editingCategory: String
    @Binding var editingAliases: String
    let onStartEdit: () -> Void
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void
    let onToggleSelect: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: onToggleSelect) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected ? .blue : .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)

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
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if VocabStore.isSuspect(entry.term) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange.opacity(0.7))
                            .help("此条目可能不适合作为语音热词（含 URL / 邮箱 / 空格 / 标点）")
                    }

                    if !entry.category.isEmpty {
                        Text(entry.category)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }

                    if !entry.aliases.isEmpty {
                        Text("✦\(entry.aliases.count)")
                            .font(.system(size: 10))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.blue.opacity(0.12), in: Capsule())
                            .foregroundStyle(.blue)
                            .help("已知错拼 \(entry.aliases.count) 个：\(entry.aliases.joined(separator: "、"))")
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

            // 编辑模式下第二行:alias 输入框
            if isEditing {
                HStack(spacing: 8) {
                    // 占位让 alias 输入跟主行右侧对齐(checkbox 13 + spacing 8 + toggle 28 + spacing 8)
                    Spacer().frame(width: 57)
                    TextField("已知错拼（逗号分隔，如 Vocab, Voizbee, was be）", text: $editingAliases)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .onSubmit(onCommit)
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
