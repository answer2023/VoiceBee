import Foundation
import WhisperKit

@main
struct WhisperKitPoC {
    static let defaultModel = "openai_whisper-large-v3-v20240930_626MB"
    /// Prompt = natural-language prior context (Whisper expects "previous transcript"
    /// style, not bare vocab list — bare list triggers compression-ratio threshold and
    /// produces empty output at temperature 0.0).
    static let defaultVocabPrompt =
        "用户经常提到这些产品名:VoiceBee、JotBee、ClearSky、WhisperKit。"

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            print("""
            Usage: WhisperKitPoC <audio-path-or-dir> [model-name] [--prompt "vocab1 vocab2 ..."]

            Modes:
              swift run WhisperKitPoC test_audio/                            # baseline only
              swift run WhisperKitPoC test_audio/ --compare                  # baseline + promptTokens, side-by-side
              swift run WhisperKitPoC test_audio/ --prompt "VoiceBee JotBee" # promptTokens only

            Default model: \(defaultModel)
            Default vocab (used by --compare): "\(defaultVocabPrompt)"
            """)
            exit(1)
        }
        let input = args[1]
        var model = defaultModel
        var promptText: String? = nil
        var compare = false
        var i = 2
        while i < args.count {
            switch args[i] {
            case "--prompt":
                if i + 1 < args.count { promptText = args[i + 1]; i += 2 } else { i += 1 }
            case "--compare":
                compare = true
                i += 1
            default:
                model = args[i]
                i += 1
            }
        }

        do {
            try await run(input: input, model: model, promptText: promptText, compare: compare)
        } catch {
            print("❌ FAILED: \(error)")
            exit(1)
        }
    }

    static func run(input: String, model: String, promptText: String?, compare: Bool) async throws {
        print("==== WhisperKit PoC ====")
        print("Model: \(model)")
        print("Input: \(input)")
        if compare {
            print("Mode: --compare (baseline + promptTokens \"\(defaultVocabPrompt)\")")
        } else if let p = promptText {
            print("Mode: promptTokens (\"\(p)\")")
        } else {
            print("Mode: baseline (no prompt)")
        }
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
        // init() is lazy — explicitly load to bring up tokenizer + Core ML models
        try await pipe.loadModels()
        let loadElapsed = Date().timeIntervalSince(loadStart)
        print(String(format: "Model load + prewarm: %.2fs", loadElapsed))
        print()

        let baseOptions = DecodingOptions(
            task: .transcribe,
            language: "zh",
            temperature: 0.0,
            detectLanguage: false
        )

        if compare {
            let vocab = defaultVocabPrompt
            let promptTokens = try encodePrompt(vocab, tokenizer: pipe.tokenizer)
            print("Encoded prompt: \"\(vocab)\" → \(promptTokens.count) tokens \(promptTokens)")
            print()

            var baseRows: [(file: String, text: String, elapsed: Double)] = []
            var promptRows: [(file: String, text: String, elapsed: Double)] = []

            print("--- Pass 1: baseline (no promptTokens) ---")
            for url in audioFiles {
                let r = try await transcribe(pipe: pipe, url: url, options: baseOptions)
                baseRows.append((url.lastPathComponent, r.text, r.elapsed))
                print(String(format: "  %@  (%.2fs)  %@", url.lastPathComponent, r.elapsed, r.text))
            }
            print()
            print("--- Pass 2: with promptTokens ---")
            // promptTokens lowers first-token logProb → trips noSpeechThreshold.
            // Disable noSpeech / logProb guards when using promptTokens.
            var promptOptions = DecodingOptions(
                task: .transcribe,
                language: "zh",
                temperature: 0.0,
                detectLanguage: false,
                promptTokens: promptTokens,
                compressionRatioThreshold: nil,
                logProbThreshold: nil,
                firstTokenLogProbThreshold: nil,
                noSpeechThreshold: nil
            )
            _ = promptOptions  // silence unused warning if struct re-init only
            for url in audioFiles {
                let r = try await transcribe(pipe: pipe, url: url, options: promptOptions)
                promptRows.append((url.lastPathComponent, r.text, r.elapsed))
                print(String(format: "  %@  (%.2fs)  %@", url.lastPathComponent, r.elapsed, r.text))
            }

            print()
            print(String(repeating: "=", count: 40))
            print("COMPARE TABLE (markdown):")
            print()
            print("| # | File | Baseline | With promptTokens | Δ time |")
            print("|---|---|---|---|---|")
            for (b, p) in zip(baseRows, promptRows) {
                let safe1 = b.text.replacingOccurrences(of: "|", with: "\\|")
                let safe2 = p.text.replacingOccurrences(of: "|", with: "\\|")
                let dt = p.elapsed - b.elapsed
                print(String(format: "|  | %@ | %@ | %@ | %+0.2fs |", b.file, safe1, safe2, dt))
            }
        } else {
            var options = baseOptions
            if let p = promptText {
                options.promptTokens = try encodePrompt(p, tokenizer: pipe.tokenizer)
                print("Encoded prompt: \"\(p)\" → \(options.promptTokens?.count ?? 0) tokens")
                print()
            }

            var rows: [(file: String, text: String, elapsed: Double)] = []
            for url in audioFiles {
                let r = try await transcribe(pipe: pipe, url: url, options: options)
                rows.append((url.lastPathComponent, r.text, r.elapsed))
                print(String(format: "▶ %@  (%.2fs)\n  %@\n", url.lastPathComponent, r.elapsed, r.text))
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
    }

    static func transcribe(pipe: WhisperKit, url: URL, options: DecodingOptions) async throws
        -> (text: String, elapsed: Double)
    {
        let started = Date()
        let results = try await pipe.transcribe(audioPath: url.path, decodeOptions: options)
        let elapsed = Date().timeIntervalSince(started)
        let text = results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text, elapsed)
    }

    /// Encode plain vocab text into Whisper prompt tokens.
    /// Mirrors ArgmaxCLI/TranscribeCLI.swift:135 — leading space + filter special tokens.
    static func encodePrompt(_ text: String, tokenizer: WhisperTokenizer?) throws -> [Int] {
        guard let tokenizer else { throw PoCError.tokenizerMissing }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let raw = tokenizer.encode(text: " " + trimmed)
        return raw.filter { $0 < tokenizer.specialTokens.specialTokenBegin }
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
        case tokenizerMissing
        var errorDescription: String? {
            switch self {
            case .notFound(let p): return "Path not found: \(p)"
            case .tokenizerMissing: return "WhisperKit tokenizer not loaded — call loadModels() or pass model name"
            }
        }
    }
}
