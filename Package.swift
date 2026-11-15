// swift-tools-version: 6.2

import PackageDescription

let strictSwift: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
    name: "Moss",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Moss", targets: ["Moss"]),
        .executable(name: "MossCLI", targets: ["MossCLI"]),
        .library(name: "MossCore", targets: ["MossCore"]),
        .library(name: "MossConfig", targets: ["MossConfig"]),
        .library(name: "MossIPC", targets: ["MossIPC"]),
    ],
    targets: [
        // The pure window-management model: geometry, layouts, workspaces and actions.
        .target(name: "MossCore", swiftSettings: strictSwift),

        // The configuration language: lossless documents, evaluation, schema.
        .target(name: "MossConfig", dependencies: ["MossCore"], swiftSettings: strictSwift),

        // Control and event sockets shared by the window manager, the CLI and the GUI.
        .target(name: "MossIPC", dependencies: ["MossCore"], swiftSettings: strictSwift),

        // The window manager engine. Talks to the operating system only through the
        // protocols in Ports/, so it runs unchanged against fakes in tests.
        .target(
            name: "MossRuntime",
            dependencies: ["MossCore", "MossConfig", "MossIPC"],
            swiftSettings: strictSwift
        ),

        // Translation between key names and the physical keys of the active keyboard layout.
        .target(name: "MossKeyboard", swiftSettings: strictSwift),

        // macOS implementations of the runtime's ports: accessibility, input, overlays.
        .target(
            name: "MossPlatform",
            dependencies: ["MossCore", "MossRuntime", "MossKeyboard"],
            swiftSettings: strictSwift
        ),

        // The settings window and menu bar panel.
        .target(
            name: "MossSettings",
            dependencies: ["MossCore", "MossConfig", "MossIPC", "MossKeyboard"],
            swiftSettings: strictSwift
        ),

        // The menu bar application.
        .executableTarget(
            name: "Moss",
            dependencies: ["MossCore", "MossConfig", "MossIPC", "MossRuntime", "MossPlatform", "MossSettings"],
            swiftSettings: strictSwift
        ),

        // The command-line interface.
        .executableTarget(
            name: "MossCLI",
            dependencies: ["MossCore", "MossConfig", "MossIPC"],
            swiftSettings: strictSwift
        ),

        // End-to-end tests, run against a live session (see Tests/E2E/README.md).
        .executableTarget(name: "WindowFactory", path: "Tests/E2E/WindowFactory"),
        .executableTarget(name: "moss-e2e", dependencies: ["MossIPC"], path: "Tests/E2E/Runner"),

        .testTarget(name: "MossCoreTests", dependencies: ["MossCore"], swiftSettings: strictSwift),
        .testTarget(name: "MossConfigTests", dependencies: ["MossConfig"], swiftSettings: strictSwift),
        .testTarget(name: "MossIPCTests", dependencies: ["MossIPC"], swiftSettings: strictSwift),
        .testTarget(name: "MossPlatformTests", dependencies: ["MossPlatform"], swiftSettings: strictSwift),
        .testTarget(name: "MossSettingsTests", dependencies: ["MossSettings", "MossIPC", "MossCore"], swiftSettings: strictSwift),
        .testTarget(
            name: "MossRuntimeTests",
            dependencies: ["MossRuntime", "MossCore", "MossConfig", "MossIPC"],
            swiftSettings: strictSwift
        ),
    ]
)
