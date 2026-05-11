import Foundation
import WhisperKit

@main
struct WhisperKitPoC {
    static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("""
            Usage: WhisperKitPoC <audio-path-or-dir> [model-name]

            Examples:
              swift run WhisperKitPoC test_audio/01.wav
              swift run WhisperKitPoC test_audio/
              swift run WhisperKitPoC test_audio/ openai_whisper-large-v3-v20240930_626MB
              swift run WhisperKitPoC test_audio/ openai_whisper-base

            Default model: \(defaultModel)
            """)
            exit(1)
        }
        let input = args[1]
        let model = args.count >= 3 ? args[2] : defaultModel

        do {
            try await run(input: input, model: model)
        } catch {
            print("❌ FAILED: \(error)")
            exit(1)
        }
    }

    static func run(input: String, model: String) async throws {
        print("==== WhisperKit PoC ====")
        print("Model: \(model)")
        print("Input: \(input)")
        print(String(repeating: "-", count: 40))

        let audioFiles = try collectAudio(at: input)
        guard !audioFiles.isEmpty else {
            print("⚠️  No .wav / .aiff / .mp3 / .m4a / .flac files found at \(input)")
            return
        }
        print("Found \(audioFiles.count) audio file(s).")
        print()

        let loadStart = Date()
        let config = WhisperKitConfig(model: model, verbose: false, logLevel: .info, prewarm: true)
        let pipe = try await WhisperKit(config)
        let loadElapsed = Date().timeIntervalSince(loadStart)
        print(String(format: "Model load + prewarm: %.2fs", loadElapsed))
        print()

        let decodeOptions = DecodingOptions(
            task: .transcribe,
            language: "zh",
            temperature: 0.0,
            detectLanguage: false
        )

        var rows: [(file: String, text: String, elapsed: Double)] = []
        for url in audioFiles {
            let started = Date()
            let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: decodeOptions)
            let elapsed = Date().timeIntervalSince(started)
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            rows.append((url.lastPathComponent, text, elapsed))
            print(String(format: "▶ %@  (%.2fs)\n  %@\n", url.lastPathComponent, elapsed, text))
        }

        print(String(repeating: "=", count: 40))
        print("Summary (markdown table):")
        print()
        print("| File | Time (s) | Transcript |")
        print("|---|---|---|")
        for r in rows {
            let safe = r.text.replacingOccurrences(of: "|", with: "\\|")
            print(String(format: "| %@ | %.2f | %@ |", r.file, r.elapsed, safe))
        }
    }

    static func collectAudio(at path: String) throws -> [URL] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            throw PoCError.notFound(path)
        }
        let supported: Set<String> = ["wav", "aiff", "aif", "mp3", "m4a", "flac"]
        if isDir.boolValue {
            let url = URL(fileURLWithPath: path)
            let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            return items
                .filter { supported.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return [URL(fileURLWithPath: path)]
    }

    enum PoCError: LocalizedError {
        case notFound(String)
        var errorDescription: String? {
            switch self {
            case .notFound(let p): return "Path not found: \(p)"
            }
        }
    }
}
