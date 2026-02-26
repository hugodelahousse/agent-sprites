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
    targets: [
        // Shared library with models and XPC protocol
        .target(
            name: "AgentSpritesCore",
            dependencies: [],
            path: "Sources/AgentSpritesCore"
        ),

        // Daemon (launchd agent providing XPC service)
        .executableTarget(
            name: "agentsprites-daemon",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/agentsprites-daemon"
        ),

        // CLI (called by Claude Code hooks)
        .executableTarget(
            name: "agentsprites-cli",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/agentsprites-cli"
        ),

        // SwiftUI Menu Bar App
        .executableTarget(
            name: "AgentSprites",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/AgentSprites",
            resources: [
                .process("Resources")
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
