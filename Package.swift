// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSprites",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentSpritesCore", targets: ["AgentSpritesCore"]),
        .executable(name: "agentsprites-daemon", targets: ["agentsprites-daemon"]),
        .executable(name: "agentsprites-cli", targets: ["agentsprites-cli"]),
        .executable(name: "AgentSprites", targets: ["AgentSprites"]),
    ],
    dependencies: [
        .package(url: "https://github.com/realm/SwiftLint.git", from: "0.57.0"),
        .package(url: "https://github.com/nicklockwood/SwiftFormat.git", from: "0.54.0"),
    ],
    targets: [
        // Shared library with models and XPC protocol
        .target(
            name: "AgentSpritesCore",
            dependencies: [],
            path: "Sources/AgentSpritesCore",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint"),
            ]
        ),

        // Daemon (launchd agent providing XPC service)
        .executableTarget(
            name: "agentsprites-daemon",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/agentsprites-daemon",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint"),
            ]
        ),

        // CLI (called by Claude Code hooks)
        .executableTarget(
            name: "agentsprites-cli",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/agentsprites-cli",
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint"),
            ]
        ),

        // SwiftUI Menu Bar App
        .executableTarget(
            name: "AgentSprites",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/AgentSprites",
            resources: [
                .process("Resources")
            ],
            plugins: [
                .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLint"),
            ]
        ),

        // Tests
        .testTarget(
            name: "AgentSpritesCoreTests",
            dependencies: ["AgentSpritesCore"],
            path: "Tests/AgentSpritesCoreTests"
        ),
    ]
)
