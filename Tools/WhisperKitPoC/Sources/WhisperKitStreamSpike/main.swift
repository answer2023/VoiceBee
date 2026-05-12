import AVFoundation
import Foundation
import WhisperKit

// Phase 2B spike — validates WhisperKit AudioStreamTranscriber real-time API
// against the live microphone, mirroring ArgmaxCLI/TranscribeCLI.swift:293-319.
//
// IMPORTANT: WhisperKit's streaming is a PULL model. It owns the mic via
// `audioProcessor.startRecordingLive(...)`. This binary therefore cannot be
// driven by an external AVAudioEngine buffer feed — the only mic capture path
// is the one WhisperKit's own AudioProcessor uses internally.
//
// Must be run from a real terminal (Terminal.app / iTerm2). The Bash sandbox
// inside Claude Code has no mic permission and no tty for Ctrl+C, so streaming
// will hang or return immediately. See docs/whisperkit-streaming-spike.md.
@main
struct WhisperKitStreamSpike {
    static let modelName = "openai_whisper-large-v3-v20240930_626MB"

    static func main() async {
        do {
            try await run()
        } catch {
            print("FAILED: \(error)")
            exit(1)
        }
    }

    static func run() async throws {
        print("==== WhisperKit Streaming Spike ====")
        print("Model: \(modelName)")
        print("Pattern: AudioStreamTranscriber + WhisperKit-owned AVAudioEngine mic")
        print(String(repeating: "-", count: 60))

        let loadStart = Date()
        print("[load] Initializing WhisperKit (lazy, then loadModels)...")
        let config = WhisperKitConfig(
            model: modelName,
            verbose: false,
            logLevel: .info,
            prewarm: true
        )
        let pipe = try await WhisperKit(config)
        try await pipe.loadModels()
        guard let tokenizer = pipe.tokenizer else {
            throw NSError(domain: "Spike", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Tokenizer not loaded"])
        }
        let loadElapsed = Date().timeIntervalSince(loadStart)
        print(String(format: "[load] Models ready in %.2fs", loadElapsed))
        print()

        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: "zh",
            temperature: 0.0,
            detectLanguage: false
        )

        // Latency probes — wall-clock from stream start to first partial / first confirmed segment.
        // Using an actor-shielded box because the callback is @Sendable and runs off-main.
        let probe = LatencyProbe()
        let streamStart = Date()

        let transcriber = AudioStreamTranscriber(
            audioEncoder: pipe.audioEncoder,
            featureExtractor: pipe.featureExtractor,
            segmentSeeker: pipe.segmentSeeker,
            textDecoder: pipe.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: pipe.audioProcessor,
            decodingOptions: decodingOptions
        ) { oldState, newState in
            // Only react to actual changes (matches ArgmaxCLI behaviour).
            guard
                oldState.currentText != newState.currentText
                    || oldState.unconfirmedSegments != newState.unconfirmedSegments
                    || oldState.confirmedSegments != newState.confirmedSegments
            else { return }

            let elapsed = Date().timeIntervalSince(streamStart)
            Task {
                let hasRealText = !newState.currentText.isEmpty
                    && newState.currentText != "Waiting for speech..."
                if hasRealText {
                    await probe.markFirstPartial(at: elapsed)
                }
                if !newState.confirmedSegments.isEmpty {
                    await probe.markFirstFinal(at: elapsed)
                }

                print("---")
                print(String(format: "[t+%6.2fs]", elapsed))
                for seg in newState.confirmedSegments {
                    print("  confirmed:   \(seg.text)")
                }
                for seg in newState.unconfirmedSegments {
                    print("  unconfirmed: \(seg.text)")
                }
                if !newState.currentText.isEmpty {
                    print("  current:     \(newState.currentText)")
                }
            }
        }

        print("Streaming will request microphone permission on first launch.")
        print("Speak for ~10 seconds, then press Ctrl+C to stop.")
        print(String(repeating: "-", count: 60))

        // Trap SIGINT so we get one chance to print latency summary before exit.
        let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        signalSource.setEventHandler {
            Task {
                let summary = await probe.summary()
                print()
                print(String(repeating: "=", count: 60))
                print("LATENCY SUMMARY")
                print(summary)
                exit(0)
            }
        }
        signalSource.resume()
        signal(SIGINT, SIG_IGN)  // SIG_IGN so DispatchSource handler runs instead of default

        try await transcriber.startStreamTranscription()
        // startStreamTranscription returns only on error / explicit stop.
        // The Ctrl+C handler above is the normal exit path.
    }
}

actor LatencyProbe {
    private var firstPartial: TimeInterval?
    private var firstFinal: TimeInterval?

    func markFirstPartial(at elapsed: TimeInterval) {
        if firstPartial == nil {
            firstPartial = elapsed
            print(String(format: ">>> first partial at t+%.2fs <<<", elapsed))
        }
    }

    func markFirstFinal(at elapsed: TimeInterval) {
        if firstFinal == nil {
            firstFinal = elapsed
            print(String(format: ">>> first confirmed segment at t+%.2fs <<<", elapsed))
        }
    }

    func summary() -> String {
        let p = firstPartial.map { String(format: "%.2fs", $0) } ?? "never"
        let f = firstFinal.map { String(format: "%.2fs", $0) } ?? "never"
        return """
          First partial:           \(p)
          First confirmed segment: \(f)
        """
    }
}
