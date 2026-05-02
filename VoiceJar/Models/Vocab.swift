import Foundation

/// 词典条目 — 用户自定义专名/术语
struct VocabEntry: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()
    var term: String                // 正确写法（如 "Claude"）
    var category: String = ""       // 产品名 / 人名 / 术语 ...
    var notes: String = ""
    var enabled: Bool = true
    var hitCount: Int = 0           // 命中次数
    var createdAt: Date = Date()
}

/// 词典存储 — JSON 持久化到 ~/Library/Application Support/VoiceBee/vocab.json
@Observable
final class VocabStore {
    private(set) var entries: [VocabEntry] = []
    private let fileURL: URL

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("VoiceBee", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("vocab.json")
        load()
    }

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

    func update(_ entry: VocabEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx] = entry
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func toggle(_ id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].enabled.toggle()
        save()
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
            VJLog.log("❌ 加载失败: \(error)", prefix: "Vocab")
        }
    }
}
