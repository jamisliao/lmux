// swift-tools-version: 6.0
import PackageDescription

// libghostty is a static library that pulls in these system frameworks.
// The list mirrors what Ghostty's own macOS Xcode target links (explicitly or
// via Swift auto-linking), plus libc++ (`-lstdc++` in Ghostty.xcodeproj).
let ghosttyLinker: [LinkerSetting] = [
    .linkedFramework("AppKit"),
    .linkedFramework("Carbon"),
    .linkedFramework("CoreGraphics"),
    .linkedFramework("CoreText"),
    .linkedFramework("CoreVideo"),
    .linkedFramework("Foundation"),
    .linkedFramework("IOSurface"),
    .linkedFramework("Metal"),
    .linkedFramework("MetalKit"),
    .linkedFramework("QuartzCore"),
    .linkedFramework("UniformTypeIdentifiers"),
    .linkedLibrary("c++"),
]

let package = Package(
    name: "lmux",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "lmux", targets: ["lmux"]),
        .executable(name: "lmux-cli", targets: ["lmux-cli"]),
        .executable(name: "lmux-imetest", targets: ["lmux-imetest"]),
        .executable(name: "lmux-apptest", targets: ["lmux-apptest"]),
    ],
    dependencies: [
        // Agent-awareness libraries (hooks socket, state machine, installer).
        .package(path: "../Core"),
    ],
    targets: [
        // Symlink to vendor/ghostty/macos/GhosttyKit.xcframework (built from
        // ghostty-org/ghostty ff23824).
        .binaryTarget(name: "GhosttyKit", path: "Frameworks/GhosttyKit.xcframework"),
        .target(
            name: "LmuxTerminal",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: ghosttyLinker
        ),
        // Design tokens (design/Tokens.swift is a symlink to this file).
        .target(name: "LmuxTokens", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Window, sidebar, workspaces/splits, agent awareness, persistence, CLI socket.
        .target(
            name: "LmuxUI",
            dependencies: ["LmuxTerminal", "LmuxTokens", "GhosttyKit",
                           .product(name: "LmuxHooks", package: "Core"),
                           .product(name: "LmuxTranscript", package: "Core"),
                           .product(name: "LmuxSessions", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // plugin：sidebar 底部的通知 bar（掛在 LmuxUI 的 installSidebarAccessory）。
        .target(
            name: "LmuxNotificationBar",
            dependencies: ["LmuxUI", "LmuxTokens"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lmux",
            dependencies: ["LmuxUI", "LmuxTerminal", "GhosttyKit", "LmuxNotificationBar"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // `lmux` command-line client (bundled as Contents/Resources/bin/lmux).
        .executableTarget(name: "lmux-cli", swiftSettings: [.swiftLanguageMode(.v5)]),
        // Headless app test harness (workspaces, splits, focus, persistence, hooks, CLI).
        .executableTarget(
            name: "lmux-apptest",
            dependencies: ["LmuxUI", "LmuxTerminal", "LmuxTokens", "GhosttyKit",
                           .product(name: "LmuxHooks", package: "Core"),
                           .product(name: "LmuxTranscript", package: "Core"),
                           .product(name: "LmuxSessions", package: "Core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "lmux-imetest",
            dependencies: ["LmuxTerminal", "LmuxUI", "GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
