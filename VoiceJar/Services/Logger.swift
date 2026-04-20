import Foundation
import os

/// 统一日志工具 — 同时输出到 os_log 和调试文件
enum VJLog {
    private static let logger = os.Logger(subsystem: "com.clearsky.VoiceJar", category: "general")
    private static let logFile = FileManager.default.temporaryDirectory.appendingPathComponent("voicejar_debug.log")

    /// 写一条日志（线程安全）
    static func log(_ msg: String, prefix: String = "") {
        let tag = prefix.isEmpty ? "" : "[\(prefix)] "
        let line = "[\(Date())] \(tag)\(msg)\n"
        logger.info("\(tag)\(msg)")

        // 文件写入用串行队列避免竞争
        queue.async {
            if let data = line.data(using: .utf8) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                } else {
                    try? data.write(to: logFile)
                }
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.clearsky.VoiceJar.logger", qos: .utility)
}
