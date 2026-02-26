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

    // Session metadata fields
    public let transcriptPath: String?

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
        case sessionId = "session_id"
        case cwd
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case error
        case notificationType = "notification_type"
        case message
        case transcriptPath = "transcript_path"

        // Alternative keys for hookEventName (defensive, may not be needed)
        case eventName = "event_name"
        case camelCaseEventName = "hookEventName"
        case shortEventName = "event"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Required fields
        self.sessionId = try container.decode(String.self, forKey: .sessionId)
        self.cwd = try container.decode(String.self, forKey: .cwd)

        // Try multiple keys for event name (official key first)
        if let name = try container.decodeIfPresent(String.self, forKey: .hookEventName) {
            self.hookEventName = name
        } else if let name = try container.decodeIfPresent(String.self, forKey: .eventName) {
            self.hookEventName = name
        } else if let name = try container.decodeIfPresent(String.self, forKey: .camelCaseEventName) {
            self.hookEventName = name
        } else if let name = try container.decodeIfPresent(String.self, forKey: .shortEventName) {
            self.hookEventName = name
        } else {
            self.hookEventName = "Unknown"
        }

        // Optional fields
        self.toolName = try container.decodeIfPresent(String.self, forKey: .toolName)

        // tool_input can be either a String or a JSON object - handle both
        if let inputString = try? container.decodeIfPresent(String.self, forKey: .toolInput) {
            self.toolInput = inputString
        } else if let inputObject = try? container.decodeIfPresent(AnyCodable.self, forKey: .toolInput) {
            // Serialize the object to JSON string
            if let data = try? JSONEncoder().encode(inputObject),
               let jsonString = String(data: data, encoding: .utf8) {
                self.toolInput = jsonString
            } else {
                self.toolInput = nil
            }
        } else {
            self.toolInput = nil
        }
        self.error = try container.decodeIfPresent(String.self, forKey: .error)
        self.notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hookEventName, forKey: .hookEventName)
        try container.encode(sessionId, forKey: .sessionId)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(toolName, forKey: .toolName)
        try container.encodeIfPresent(toolInput, forKey: .toolInput)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(notificationType, forKey: .notificationType)
        try container.encodeIfPresent(message, forKey: .message)
        try container.encodeIfPresent(transcriptPath, forKey: .transcriptPath)
    }

    public init(
        hookEventName: String,
        sessionId: String,
        cwd: String,
        toolName: String? = nil,
        toolInput: String? = nil,
        error: String? = nil,
        notificationType: String? = nil,
        message: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.hookEventName = hookEventName
        self.sessionId = sessionId
        self.cwd = cwd
        self.toolName = toolName
        self.toolInput = toolInput
        self.error = error
        self.notificationType = notificationType
        self.message = message
        self.transcriptPath = transcriptPath
    }

    /// Parse a HookEvent from JSON data (typically from stdin)
    public static func parse(from data: Data) throws -> Self {
        try JSONDecoder().decode(Self.self, from: data)
    }

    /// Parse a HookEvent from a JSON string
    public static func parse(from jsonString: String) throws -> Self {
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
        case "PostToolUse":
            // Tool completed successfully - permission was granted (if needed)
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

// MARK: - AnyCodable Helper

/// A type-erased Codable value for handling arbitrary JSON
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unable to encode value"))
        }
    }
}
