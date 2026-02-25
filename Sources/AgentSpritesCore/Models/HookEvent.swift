import Foundation

/// Represents a hook event received from Claude Code via stdin
public struct HookEvent: Codable, Sendable {
    public let hookEventName: String
    public let sessionId: String
    public let cwd: String

    // Optional fields that may be present depending on event type
    public let toolName: String?
    public let toolInput: String?
    public let error: String?

    // Notification-specific fields
    public let notificationType: String?
    public let message: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case error
        case notificationType = "notification_type"
        case message
    }

    public init(
        hookEventName: String,
        sessionId: String,
        cwd: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        error: String? = nil,
        notificationType: String? = nil,
        message: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.error = error
        self.notificationType = notificationType
        self.message = message
    }

    /// Parse a HookEvent from JSON data (typically from stdin)
    public static func parse(from data: Data) throws -> HookEvent {
        let decoder = JSONDecoder()
        return try decoder.decode(HookEvent.self, from: data)
    }

    /// Parse a HookEvent from a JSON string
    public static func parse(from jsonString: String) throws -> HookEvent {
        guard let data = jsonString.data(using: .utf8) else {
            throw HookEventError.invalidEncoding
        }
        return try parse(from: data)
    }

    /// Determine the session status based on this event
    public func determineStatus() -> SessionStatus {
        switch hookEventName {
        case "SessionStart":
            return .idle
        case "UserPromptSubmit":
            return .working
        case "Stop":
            return .done
        case "Notification":
            return determineNotificationStatus()
        case "PermissionRequest":
            return .waitingForPermission
        case "PostToolUseFailure":
            return .error
        case "SubagentStart", "SubagentStop":
            return .working
        case "PreCompact":
            return .working
        default:
            return .working
        }
    }

    /// Determine status based on notification type
    private func determineNotificationStatus() -> SessionStatus {
        switch notificationType {
        case "permission_prompt":
            return .waitingForPermission
        case "idle_prompt":
            return .idle
        case "elicitation_dialog":
            return .waitingForInput
        case "auth_success":
            // Auth success is informational, doesn't change working state
            return .working
        default:
            // Unknown notification type, assume waiting for input
            return .waitingForInput
        }
    }

    /// Whether this event should remove the session
    public var shouldRemoveSession: Bool {
        return hookEventName == "SessionEnd"
    }
}

public enum HookEventError: Error, LocalizedError {
    case invalidEncoding
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Invalid UTF-8 encoding in hook event data"
        case .parseError(let message):
            return "Failed to parse hook event: \(message)"
        }
    }
}
