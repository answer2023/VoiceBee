import Foundation

/// 词典条目 — 用户自定义专名/术语
struct VocabEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var term: String                // 正确写法（如 "Claude"）
    var category: String = ""       // 产品名 / 人名 / 术语 ...
    var notes: String = ""
    var enabled: Bool = true
    var hitCount: Int = 0           // 命中次数
    /// 已知错拼/别名 — 给 VocabPostprocessor 精确替换用。Phase 3-A 引入,旧 JSON 缺此字段时 decode 容错为 []
    var aliases: [String] = []
    var createdAt: Date = Date()

    init(
        id: UUID = UUID(),
        term: String,
        category: String = "",
        notes: String = "",
        enabled: Bool = true,
        hitCount: Int = 0,
        aliases: [String] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.category = category
        self.notes = notes
        self.enabled = enabled
        self.hitCount = hitCount
        self.aliases = aliases
        self.createdAt = createdAt
    }

    // Phase 3-A:旧 vocab.json 不含 aliases / 部分字段,用 decodeIfPresent 全量容错
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.term = try c.decode(String.self, forKey: .term)
        self.category = try c.decodeIfPresent(String.self, forKey: .category) ?? ""
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.hitCount = try c.decodeIfPresent(Int.self, forKey: .hitCount) ?? 0
        self.aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, category, notes, enabled, hitCount, aliases, createdAt
    }
}

/// 词典存储 — JSON 持久化到 ~/Library/Application Support/VoiceBee/vocab.json
@Observable
final class VocabStore {
    private(set) var entries: [VocabEntry] = []
    /// vocab.json 存在但 decode 失败 — 与「首次运行(文件不存在)」区分,防止默认词典覆盖用户数据
    private(set) var loadFailed = false
    private let fileURL: URL

    /// - Parameter fileURL: 词典 JSON 路径 — 测试注入用;nil 走生产默认 Application Support/VoiceBee/vocab.json
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("VoiceBee", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("vocab.json")
        }
        load()
        ensureDefaultsIfEmpty()
    }

    /// Phase 3-A (P9=A):仅在词典完全为空时预置营销专名 + 已知错拼.
    /// 不覆盖用户已有数据 — 老用户哪怕只有一条自定义条目,默认词典都不会注入.
    private func ensureDefaultsIfEmpty() {
        // load 失败时 entries 为空但不是首次运行 — 跳过注入,避免 save() 覆盖磁盘上的用户数据
        guard !loadFailed else { return }
        guard entries.isEmpty else { return }
        entries = Self.defaultEntries
        save()
    }

    /// 营销专名默认词典 — alias 来自 PoC 实测错例(SFSpeech / WhisperKit large-v3 large-v3)
    /// 来源:docs/whisperkit-poc-results.md C 节 + CLAUDE.md 「专名词典注入失效」
    static let defaultEntries: [VocabEntry] = [
        VocabEntry(
            term: "VoiceBee",
            category: "产品名",
            aliases: ["Vocab", "Voizbee", "Boysbee", "Vorce P", "was be", "VB", "Voice Bee", "voice bee"]
        ),
        VocabEntry(
            term: "JotBee",
            category: "产品名",
            aliases: ["Jotby", "Jot B", "JotB", "Jot Bee", "jot bee"]
        ),
        VocabEntry(
            term: "ClearSky",
            category: "团队",
            aliases: ["Clear Sky", "clear sky", "Clearsky"]
        ),
        VocabEntry(
            term: "WhisperKit",
            category: "技术",
            aliases: ["Whisper Kit", "Whisper kit", "whisper kit", "Whisperkit"]
        ),
        VocabEntry(
            term: "macOS",
            category: "技术",
            aliases: ["MacOS", "Mac OS", "mac OS", "Macos", "mac os"]
        )
    ]

    /// 启用中的词条（用于 ASR contextualStrings 与 polish prompt 注入）
    var activeTerms: [String] {
        entries.filter { $0.enabled && !$0.term.isEmpty }.map(\.term)
    }

    /// 所有 term 小写集合（去重判断）
    var existingTermSet: Set<String> {
        Set(entries.map { $0.term.lowercased() })
    }

    func add(_ entry: VocabEntry) {
        guard !entry.term.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        guard !existingTermSet.contains(entry.term.lowercased()) else { return }
        entries.append(entry)
        save()
    }

    /// 批量添加 — 单次落盘；返回 (实际新增数, 跳过重复数)
    @discardableResult
    func addBatch(_ newEntries: [VocabEntry]) -> (added: Int, skipped: Int) {
        var existing = existingTermSet
        var added = 0
        var skipped = 0
        for entry in newEntries {
            let key = entry.term.trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { skipped += 1; continue }
            let lower = key.lowercased()
            if existing.contains(lower) { skipped += 1; continue }
            existing.insert(lower)
            var normalized = entry
            normalized.term = key
            entries.append(normalized)
            added += 1
        }
        if added > 0 { save() }
        return (added, skipped)
    }

    /// 文本解析为词条列表
    /// - 兼容 Rime 词典：自动跳过 `---` 之间的 YAML frontmatter；Tab 分隔行只取第一列（丢弃编码/权重）
    /// - 兼容用户列表：`,` / `|` 分隔时第一段为 term、第二段为 category
    /// - `#` 开头的行视为注释跳过
    static func parseImport(_ text: String) -> [VocabEntry] {
        var result: [VocabEntry] = []
        var inFrontmatter = false
        var frontmatterClosed = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // YAML frontmatter 边界：`---` 开始（也可关闭），`...` 关闭（YAML doc end marker，Rime 用）
            if line == "---" || line == "..." {
                if !frontmatterClosed {
                    if inFrontmatter {
                        inFrontmatter = false
                        frontmatterClosed = true
                    } else if line == "---" {
                        inFrontmatter = true
                    }
                }
                continue
            }
            if inFrontmatter { continue }

            guard !line.isEmpty, !line.hasPrefix("#") else { continue }

            // Tab 分隔（Rime 词典格式：term\tcode\tweight）→ 只取第一列
            if line.contains("\t") {
                let term = String(line.split(separator: "\t").first ?? "")
                    .trimmingCharacters(in: .whitespaces)
                guard !term.isEmpty else { continue }
                result.append(VocabEntry(term: term, category: ""))
                continue
            }

            // 逗号 / 管道分隔（用户友好格式：term, category）
            let separators: [Character] = [",", "|"]
            var term = line
            var category = ""
            if let sep = separators.first(where: { line.contains($0) }),
               let idx = line.firstIndex(of: sep) {
                term = String(line[..<idx]).trimmingCharacters(in: .whitespaces)
                category = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            }
            guard !term.isEmpty else { continue }
            result.append(VocabEntry(term: term, category: category))
        }
        return result
    }

    func update(_ entry: VocabEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeBatch(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        entries.removeAll { ids.contains($0.id) }
        save()
    }

    func toggle(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].enabled.toggle()
        save()
    }

    func setEnabledBatch(_ ids: Set<UUID>, enabled: Bool) {
        guard !ids.isEmpty else { return }
        var changed = false
        for idx in entries.indices where ids.contains(entries[idx].id) {
            if entries[idx].enabled != enabled {
                entries[idx].enabled = enabled
                changed = true
            }
        }
        if changed { save() }
    }

    /// 判断条目是否「可疑」— 不太适合作为 ASR 热词
    /// URL / 邮箱 / 含空格的句子 / 纯标点 / 过长 都算可疑
    static func isSuspect(_ term: String) -> Bool {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return true }
        if t.contains("://") || t.contains("http") { return true }
        if t.contains("@") && t.contains(".") { return true }   // email-like
        if t.contains(" ") || t.contains("\t") { return true }  // sentence/phrase
        if t.count > 30 { return true }
        // 不含字母 / 数字 / CJK = 纯标点或表情
        let usefulChars = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        if t.unicodeScalars.first(where: { usefulChars.contains($0) }) == nil { return true }
        return false
    }

    /// 导出为 JSON 字符串（与持久化文件相同格式，可直接复制为 vocab.json）
    func exportJSON() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// 导出为 CSV（term, category, enabled, hitCount, createdAt）
    func exportCSV() -> String {
        var lines = ["term,category,enabled,hitCount,createdAt"]
        let formatter = ISO8601DateFormatter()
        for entry in entries {
            let term = csvEscape(entry.term)
            let category = csvEscape(entry.category)
            let enabled = entry.enabled ? "true" : "false"
            let date = formatter.string(from: entry.createdAt)
            lines.append("\(term),\(category),\(enabled),\(entry.hitCount),\(date)")
        }
        return lines.joined(separator: "\n")
    }

    private func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }

    /// 在润色后扫描结果，为每条命中的词条 +1
    func recordHits(in text: String) {
        guard !text.isEmpty else { return }
        var changed = false
        for idx in entries.indices where entries[idx].enabled {
            let term = entries[idx].term
            guard !term.isEmpty else { continue }
            if text.range(of: term, options: .caseInsensitive) != nil {
                entries[idx].hitCount += 1
                changed = true
            }
        }
        if changed { save() }
    }

    // MARK: - 候选词挖掘

    /// 从历史记录中挖掘候选词条：连续大写开头的英文专名，出现 ≥2 次
    static func mineCandidates(from history: [TranscriptionRecord], existing: Set<String>) -> [String] {
        var counts: [String: Int] = [:]
        // 匹配：以大写字母开头、长度 ≥3 的字母数字串（ChatGPT / Claude / OpenLess 等）
        let pattern = #"\b[A-Z][A-Za-z0-9]{2,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        for record in history {
            let text = record.polishedText.isEmpty ? record.rawText : record.polishedText
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match, let r = Range(match.range, in: text) else { return }
                let word = String(text[r])
                counts[word, default: 0] += 1
            }
        }

        let candidates = counts
            .filter { $0.value >= 2 && !existing.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .map(\.key)
        return Array(candidates.prefix(20))
    }

    // MARK: - 持久化

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entries)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            VJLog.log("❌ 保存失败: \(error)", prefix: "Vocab")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            entries = try decoder.decode([VocabEntry].self, from: data)
        } catch {
            // decode 失败 ≠ 首次运行:把损坏文件挪到 .bak 保留现场,防止后续 save() 原地覆盖
            loadFailed = true
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = fileURL.deletingLastPathComponent()
                .appendingPathComponent("vocab.json.corrupt-\(timestamp).bak")
            do {
                try FileManager.default.moveItem(at: fileURL, to: backupURL)
                VJLog.log("❌ 加载失败,损坏文件已备份到 \(backupURL.lastPathComponent): \(error)", prefix: "Vocab")
            } catch let moveError {
                VJLog.log("❌ 加载失败,且备份损坏文件也失败(原文件留在原位): \(error) / 备份错误: \(moveError)", prefix: "Vocab")
            }
        }
    }
}
