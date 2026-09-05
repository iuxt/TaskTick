// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
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
                "TaskTickCore"
            ],
            path: "Sources",
            // AppIcon.icns is copied into the final app bundle by the build
            // scripts; it is not a SwiftPM resource.
            exclude: ["TaskTickCore", "Resources/AppIcon.icns"]
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTickApp", "TaskTickCore"],
            path: "Tests/AppTests"
        )
    ]
)
