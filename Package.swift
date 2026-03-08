// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AgentSprites",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AgentSpritesCore", targets: ["AgentSpritesCore"]),
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
            path: "Sources/AgentSpritesCore"
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

        // Stress test tool
        .executableTarget(
            name: "agentsprites-stress",
            dependencies: ["AgentSpritesCore"],
            path: "Sources/agentsprites-stress"
        ),

        // Tests
        .testTarget(
            name: "AgentSpritesCoreTests",
            dependencies: ["AgentSpritesCore"],
            path: "Tests/AgentSpritesCoreTests"
        ),
    ]
)
