import Foundation
import os.log

private let logger = Logger(subsystem: "com.agentsprites.app", category: "HookInstaller")

/// Result of checking for existing AgentSprites hooks
enum ExistingHooksStatus: Equatable {
    /// No AgentSprites hooks found
    case none
    /// Hooks found pointing to current app's CLI
    case currentApp
    /// Hooks found pointing to a different AgentSprites installation
    case differentApp(path: String)
}

/// Manages Claude Code hook installation
enum HookInstaller {
    private static let claudeSettingsPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    private static let hookEvents = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "Stop",
        "Notification",
        "PermissionRequest",
        "SubagentStart",
        "SubagentStop",
        // PostToolUse removed - too noisy, we infer permission granted from subsequent events
        "PostToolUseFailure",
        "PreCompact"
    ]

    /// Path to the bundled CLI executable
    static var bundledCLIPath: String? {
        // Look for CLI in the app bundle's Helpers directory
        guard let bundlePath = Bundle.main.bundlePath as String? else { return nil }
        let helpersPath = (bundlePath as NSString).appendingPathComponent("Contents/Helpers/agentsprites-cli")

        if FileManager.default.fileExists(atPath: helpersPath) {
            return helpersPath
        }

        // Fallback: check MacOS directory (for development builds)
        let macOSPath = (bundlePath as NSString).appendingPathComponent("Contents/MacOS/agentsprites-cli")
        if FileManager.default.fileExists(atPath: macOSPath) {
            return macOSPath
        }

        return nil
    }

    /// Check for existing AgentSprites hooks and their status
    static func checkExistingHooks() -> ExistingHooksStatus {
        guard let settings = loadSettings(),
              let hooks = settings["hooks"] as? [String: Any] else {
            return .none
        }

        let currentCLIPath = bundledCLIPath

        // Find any agentsprites-cli hooks
        for event in hookEvents {
            if let eventHooks = hooks[event] as? [[String: Any]] {
                for entry in eventHooks {
                    if let innerHooks = entry["hooks"] as? [[String: Any]] {
                        for hook in innerHooks {
                            if let command = hook["command"] as? String,
                               command.contains("agentsprites-cli") {
                                // Found an AgentSprites hook
                                if command == currentCLIPath {
                                    return .currentApp
                                } else {
                                    return .differentApp(path: command)
                                }
                            }
                        }
                    }
                }
            }
        }

        return .none
    }

    /// Check if hooks are installed for the current app
    static func areHooksInstalled() -> Bool {
        checkExistingHooks() == .currentApp
    }

    /// Remove ALL AgentSprites hooks (any path containing "agentsprites-cli")
    static func removeAllAgentSpritesHooks() -> Bool {
        guard var settings = loadSettings(),
              var hooks = settings["hooks"] as? [String: Any] else {
            return true // Nothing to remove
        }

        logger.info("Removing all AgentSprites hooks...")

        var removedCount = 0

        // Remove agentsprites-cli hooks from each event
        for event in hookEvents {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }

            let originalCount = eventHooks.count
            eventHooks.removeAll { entry in
                if let innerHooks = entry["hooks"] as? [[String: Any]] {
                    return innerHooks.contains { hook in
                        if let command = hook["command"] as? String {
                            return command.contains("agentsprites-cli")
                        }
                        return false
                    }
                }
                return false
            }

            removedCount += originalCount - eventHooks.count

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = eventHooks
            }
        }

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsPath)
            logger.info("Removed \(removedCount, privacy: .public) AgentSprites hook entries")
            return true
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Install hooks to Claude Code settings
    /// Removes any existing AgentSprites hooks first, then installs for current app
    /// Returns true on success, false on failure
    static func installHooks() -> Bool {
        guard let cliPath = bundledCLIPath else {
            logger.error("Cannot find bundled CLI path for hook installation")
            return false
        }

        logger.info("Installing hooks with CLI path: \(cliPath, privacy: .public)")

        // First, remove any existing AgentSprites hooks (old or from different location)
        _ = removeAllAgentSpritesHooks()

        // Ensure .claude directory exists
        let claudeDir = claudeSettingsPath.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create .claude directory: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Load or create settings
        var settings = loadSettings() ?? [:]

        // Ensure hooks dictionary exists
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // Hook entry format
        let hookEntry: [String: Any] = [
            "matcher": "",
            "hooks": [
                [
                    "type": "command",
                    "command": cliPath,
                    "timeout": 5000,
                    "async": true
                ]
            ]
        ]

        // Add hooks for each event
        for event in hookEvents {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []
            eventHooks.append(hookEntry)
            hooks[event] = eventHooks
        }

        settings["hooks"] = hooks

        // Save settings
        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsPath)
            logger.info("Hooks installed successfully")
            return true
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Remove hooks for current app only from Claude Code settings
    static func uninstallHooks() -> Bool {
        guard let cliPath = bundledCLIPath else {
            return false
        }

        guard var settings = loadSettings(),
              var hooks = settings["hooks"] as? [String: Any] else {
            return true // Nothing to remove
        }

        // Remove only our hooks from each event
        for event in hookEvents {
            guard var eventHooks = hooks[event] as? [[String: Any]] else { continue }

            eventHooks.removeAll { entry in
                if let innerHooks = entry["hooks"] as? [[String: Any]] {
                    return innerHooks.contains { hook in
                        (hook["command"] as? String) == cliPath
                    }
                }
                return false
            }

            if eventHooks.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = eventHooks
            }
        }

        settings["hooks"] = hooks

        do {
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: claudeSettingsPath)
            logger.info("Hooks uninstalled successfully")
            return true
        } catch {
            logger.error("Failed to save settings: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private Helpers

    private static func loadSettings() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: claudeSettingsPath)
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            logger.error("Failed to load settings: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
