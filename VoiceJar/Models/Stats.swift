import Foundation

/// 累计使用统计 — 持久化到 UserDefaults
/// 与 history（仅内存 50 条）分离，保证长期数据不丢
@Observable
final class StatsStore {
    private(set) var totalRecords: Int = 0
    private(set) var totalChars: Int = 0
    private(set) var totalSeconds: Double = 0
    private(set) var firstUsedAt: Date?

    /// 假设手打 60 字/分钟（行业基准，与 Typeless / OpenLess 一致）
    private let typingCharsPerMinute: Double = 60

    init() { load() }

    func record(chars: Int, seconds: Double) {
        totalRecords += 1
        totalChars += chars
        totalSeconds += seconds
        if firstUsedAt == nil { firstUsedAt = Date() }
        save()
    }

    func reset() {
        totalRecords = 0
        totalChars = 0
        totalSeconds = 0
        firstUsedAt = nil
        save()
    }

    /// 字 / 分钟
    var charsPerMinute: Double {
        guard totalSeconds > 0 else { return 0 }
        return Double(totalChars) / (totalSeconds / 60)
    }

    /// 节省时间（秒）— 手打耗时 - 实际录音耗时
    var timeSavedSeconds: Double {
        let typingSeconds = Double(totalChars) / typingCharsPerMinute * 60
        return max(0, typingSeconds - totalSeconds)
    }

    private func save() {
        let d = UserDefaults.standard
        d.set(totalRecords, forKey: "stats_totalRecords")
        d.set(totalChars, forKey: "stats_totalChars")
        d.set(totalSeconds, forKey: "stats_totalSeconds")
        if let f = firstUsedAt {
            d.set(f, forKey: "stats_firstUsedAt")
        }
    }

    private func load() {
        let d = UserDefaults.standard
        totalRecords = d.integer(forKey: "stats_totalRecords")
        totalChars = d.integer(forKey: "stats_totalChars")
        totalSeconds = d.double(forKey: "stats_totalSeconds")
        firstUsedAt = d.object(forKey: "stats_firstUsedAt") as? Date
    }
}

/// 时长格式化助手
enum DurationFormat {
    /// 秒 → "1h 23m" / "5m 12s" / "45s"
    static func compact(seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let m = total / 60
            let s = total % 60
            return s > 0 ? "\(m)m \(s)s" : "\(m)m"
        }
        let h = total / 3600
        let m = (total % 3600) / 60
        return m > 0 ? "\(h)h \(m)m" : "\(h)h"
    }
}
