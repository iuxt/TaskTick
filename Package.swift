// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "1.9.4")
    ],
    targets: [
        .target(
            name: "TaskTickCore",
            path: "Sources/TaskTickCore",
            resources: [
                .process("Localization")
            ]
        ),
        .executableTarget(
            name: "TaskTickApp",
            dependencies: [
                "TaskTickCore",
                // Per-task global shortcuts (issue #49): its Recorder is the
                // native-looking control, and it warns about chords the system
                // or our own main menu already claims. The CLI target stays
                // free of it — shortcuts are a GUI concern.
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources",
            // AppIcon.icns is copied into the final app bundle by the build
            // scripts; it is not a SwiftPM resource.
            exclude: ["TaskTickCore", "CLI", "Resources/AppIcon.icns"]
        ),
        .executableTarget(
            name: "tasktick",
            dependencies: [
                "TaskTickCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTickApp", "TaskTickCore"],
            path: "Tests/AppTests"
        ),
        .testTarget(
            name: "CLITests",
            dependencies: ["tasktick", "TaskTickCore"],
            path: "Tests/CLITests"
        )
    ]
)
