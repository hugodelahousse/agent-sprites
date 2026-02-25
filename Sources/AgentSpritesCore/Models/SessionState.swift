import Foundation

/// Represents the current status of a Claude Code session
public enum SessionStatus: String, Codable, Sendable {
    case idle
    case working
    case waitingForInput
    case waitingForPermission
    case error
    case done

    /// Display color name for UI
    public var colorName: String {
        switch self {
        case .idle: return "gray"
        case .working: return "blue"
        case .waitingForInput: return "yellow"
        case .waitingForPermission: return "red"
        case .error: return "red"
        case .done: return "green"
        }
    }

    /// Human-readable status description
    public var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .waitingForInput: return "Waiting for Input"
        case .waitingForPermission: return "Waiting for Permission"
        case .error: return "Error"
        case .done: return "Done"
        }
    }
}

/// Represents the state of a single Claude Code session
public struct SessionState: Codable, Sendable, Identifiable {
    public let id: String  // session_id from Claude Code
    public var status: SessionStatus
    public var workingDirectory: String
    public var lastUpdated: Date
    public var lastEventName: String?
    public var tty: String?  // TTY device path for terminal focusing
    public var bundleId: String?  // App bundle ID for activation

    public init(
        id: String,
        status: SessionStatus = .idle,
        workingDirectory: String,
        lastUpdated: Date = Date(),
        lastEventName: String? = nil,
        tty: String? = nil,
        bundleId: String? = nil
    ) {
        self.id = id
        self.status = status
        self.workingDirectory = workingDirectory
        self.lastUpdated = lastUpdated
        self.lastEventName = lastEventName
        self.tty = tty
        self.bundleId = bundleId
    }

    /// Short display name derived from working directory
    public var displayName: String {
        return (workingDirectory as NSString).lastPathComponent
    }
}

/// Collection of all session states for persistence
public struct SessionStore: Codable, Sendable {
    public var sessions: [String: SessionState]
    public var lastUpdated: Date

    public init(sessions: [String: SessionState] = [:], lastUpdated: Date = Date()) {
        self.sessions = sessions
        self.lastUpdated = lastUpdated
    }

    /// Active sessions (not idle for too long)
    public var activeSessions: [SessionState] {
        return sessions.values.sorted { $0.lastUpdated > $1.lastUpdated }
    }
}
