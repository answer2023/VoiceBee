import Foundation

/// ASR-agnostic 拼写后处理器(Phase 3-A).
///
/// 目的:把 ASR 输出的错拼专名映射回 vocab 里的正确拼写,在 polish 之前执行.
/// SFSpeech 错例:VoiceBee → "Vocab" / "was be";WhisperKit 错例:VoiceBee → "Voizbee".
/// 调用点:VoiceEngine.startStreaming 的 onFinal closure(P3=B).
///
/// 算法(P1=C 双层):
///   1. **alias 精确匹配**(case-insensitive,case-preserving 输出) — 用户/默认 vocab 维护的错拼字典
///   2. **编辑距离 fallback** — 对未在 alias 中命中、看起来像英文专名的 token,在 vocab 里找最近的 term
///      阈值(P6=B):`distance ≤ max(1, term.count / 4)` AND `term.count >= 4`
///
/// partial 不调(P4=A) — partial 高频且 overlay 是临时显示,只对 final 段矫正.
enum VocabPostprocessor {

    /// 对单段文本 apply vocab 矫正.纯函数,无副作用.
    /// - vocab: 完整 VocabEntry 列表(disabled 条目在内部 filter 掉)
    static func apply(_ text: String, vocab: [VocabEntry]) -> String {
        guard !text.isEmpty else { return text }
        let active = vocab.filter { $0.enabled && !$0.term.isEmpty }
        guard !active.isEmpty else { return text }

        var result = text
        result = aliasPass(text: result, vocab: active)
        result = fuzzyPass(text: result, vocab: active)
        return result
    }

    // MARK: - Pass 1: alias 精确匹配

    /// 把所有 alias 按长度倒序(避免短 alias 吞掉长 alias 的前缀),逐个 case-insensitive 替换为 term.
    private static func aliasPass(text: String, vocab: [VocabEntry]) -> String {
        var pairs: [(alias: String, term: String)] = []
        for entry in vocab {
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                pairs.append((trimmed, entry.term))
            }
        }
        guard !pairs.isEmpty else { return text }
        pairs.sort { $0.alias.count > $1.alias.count }

        var result = text
        for pair in pairs {
            result = replaceAlias(in: result, alias: pair.alias, term: pair.term)
        }
        return result
    }

    /// case-insensitive 替换 alias → term.ASCII alias 用 ASCII-only word boundary
    /// (避免 "vb" 替换 "vba",同时确保中英紧贴时仍能命中:"今天Voizbee這個" 必须能命中 "Voizbee").
    /// 含 CJK 或空格的 alias 用 substring 替换.
    ///
    /// 不能用 `\b` — ICU regex 把 CJK 也算 word char,"天"和"V"之间没有 \b boundary,
    /// 导致中英紧贴的 ASR 输出无法被 alias pass 命中(Phase 3-A 测试发现).
    /// 改用 `(?<![A-Za-z0-9])` + `(?![A-Za-z0-9])` 自定义只把 ASCII letter/digit 视为 word char.
    private static func replaceAlias(in text: String, alias: String, term: String) -> String {
        let isAscii = alias.unicodeScalars.allSatisfy { $0.isASCII }
        let containsSpace = alias.contains(" ")
        let pattern: String
        if isAscii && !containsSpace {
            let escaped = NSRegularExpression.escapedPattern(for: alias)
            pattern = "(?<![A-Za-z0-9])" + escaped + "(?![A-Za-z0-9])"
        } else {
            // 含空格(如 "Voice Bee" / "Mac OS")或 CJK:直接 substring,大小写不敏感
            pattern = NSRegularExpression.escapedPattern(for: alias)
        }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: term)
        )
    }

    // MARK: - Pass 2: 编辑距离 fallback

    /// 提取 transcript 里所有 ASCII 英文专名样 token(以字母开头,长度 ≥3),
    /// 跟 vocab 里 length ≥4 的英文 term 比距离,命中阈值就替换.
    /// 仅处理英文 token — 中文 ASR 错拼一般不是字符编辑距离问题,跳过避免误改.
    private static func fuzzyPass(text: String, vocab: [VocabEntry]) -> String {
        let englishTerms: [String] = vocab
            .map(\.term)
            .filter { term in
                term.count >= 4 && term.unicodeScalars.allSatisfy { $0.isASCII }
            }
        guard !englishTerms.isEmpty else { return text }

        let pattern = #"\b[A-Za-z][A-Za-z0-9]{2,}\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsRange)

        // 从后往前替换,避免 range 偏移
        var working = text
        for match in matches.reversed() {
            guard let swiftRange = Range(match.range, in: working) else { continue }
            let word = String(working[swiftRange])

            // 已经是某个 term 本身(case-insensitive)→ 跳过
            if englishTerms.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
                continue
            }
            // 找最近 term;命中则替换
            if let best = nearestTerm(to: word, candidates: englishTerms) {
                working.replaceSubrange(swiftRange, with: best)
            }
        }
        return working
    }

    /// 在英文 term 候选中找编辑距离 ≤ 阈值的最近 term.
    /// 阈值公式(P6=B):`max(1, term.count / 4)`(整数除 = floor,等价 term.count × 0.25 向下取整)
    /// 长度门槛:term.count >= 4 已在 fuzzyPass 入口 filter
    private static func nearestTerm(to word: String, candidates: [String]) -> String? {
        let wordLower = word.lowercased()
        var best: (term: String, distance: Int)? = nil
        for term in candidates {
            let threshold = max(1, term.count / 4)
            // 长度差超过阈值不可能 ≤ 阈值,提前剪枝
            if abs(term.count - word.count) > threshold { continue }
            let dist = levenshtein(wordLower, term.lowercased())
            if dist == 0 { continue }   // 大小写差,Pass 1 应已处理(或用户没配 alias);保守不动
            if dist <= threshold {
                if best == nil || dist < best!.distance {
                    best = (term, dist)
                }
            }
        }
        return best?.term
    }

    /// Levenshtein 编辑距离 — Swift Character 是 Unicode grapheme cluster,跨脚本安全.
    /// 经典两行 DP,O(m × n) 时间,O(min(m,n)) 空间.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        let m = ac.count, n = bc.count
        if m == 0 { return n }
        if n == 0 { return m }
        var prev = Array(0...n)
        var curr = [Int](repeating: 0, count: n + 1)
        for i in 1...m {
            curr[0] = i
            for j in 1...n {
                let cost = ac[i - 1] == bc[j - 1] ? 0 : 1
                curr[j] = min(
                    prev[j] + 1,        // deletion
                    curr[j - 1] + 1,    // insertion
                    prev[j - 1] + cost  // substitution
                )
            }
            swap(&prev, &curr)
        }
        return prev[n]
    }
}
