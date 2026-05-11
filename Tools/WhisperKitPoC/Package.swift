// swift-tools-version:5.10
import PackageDescription

// PoC for WhisperKit ASR engine — runs standalone via `swift run`, fully
// isolated from the main VoiceBee app (different SPM cache, different build).
// See ../../docs/whisperkit-poc-results.md for findings.

let package = Package(
    name: "WhisperKitPoC",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhisperKitPoC",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]
        ),
    ]
)
