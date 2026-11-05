// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LmuxCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "LmuxTranscript", targets: ["LmuxTranscript"]),
        .library(name: "LmuxHooks", targets: ["LmuxHooks"]),
        .library(name: "LmuxSessions", targets: ["LmuxSessions"]),
    ],
    targets: [
        // PrivateFile alone, so lmux-hook (settings.json writes) doesn't link the transcript code.
        .target(name: "LmuxPrivateFile"),
        .target(name: "LmuxTranscript", dependencies: ["LmuxPrivateFile"], exclude: ["FORMAT.md"]),
        .target(name: "LmuxHooks", dependencies: ["LmuxPrivateFile"]),
        .executableTarget(name: "lmux-transcript", dependencies: ["LmuxTranscript"]),
        .executableTarget(name: "lmux-hook", dependencies: ["LmuxHooks"]),
        .testTarget(name: "LmuxTranscriptTests", dependencies: ["LmuxTranscript"], resources: [.copy("Fixtures")]),
        .testTarget(name: "LmuxHooksTests", dependencies: ["LmuxHooks", "LmuxPrivateFile"]),
        .target(name: "LmuxSessions", dependencies: ["LmuxTranscript"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LmuxSessionsTests", dependencies: ["LmuxSessions"]),
    ]
)
