import Foundation

/// Event data sent from CLI to App via Distributed Notifications
/// This is the payload format for session updates
public struct SessionEvent: Codable, Sendable {
    public let sessionId: String
    public let eventName: String
    public let workingDirectory: String
    public let tty: String?
    public let bundleId: String?
    public let summary: String?
    public let gitBranch: String?
    public let notificationType: String?

    public init(
        sessionId: String,
        eventName: String,
        workingDirectory: String,
        tty: String? = nil,
        bundleId: String? = nil,
        summary: String? = nil,
        gitBranch: String? = nil,
        notificationType: String? = nil
    ) {
        self.sessionId = sessionId
        self.eventName = eventName
        self.workingDirectory = workingDirectory
        self.tty = tty
        self.bundleId = bundleId
        self.summary = summary
        self.gitBranch = gitBranch
        self.notificationType = notificationType
    }

    /// Create a SessionEvent from a HookEvent
    public init(from hookEvent: HookEvent, tty: String? = nil, bundleId: String? = nil, summary: String? = nil, gitBranch: String? = nil) {
        self.sessionId = hookEvent.sessionId
        self.eventName = hookEvent.hookEventName
        self.workingDirectory = hookEvent.cwd
        self.tty = tty
        self.bundleId = bundleId
        self.summary = summary
        self.gitBranch = gitBranch
        self.notificationType = hookEvent.notificationType
    }

    /// Encode to JSON string for notification payload
    public func toJSONString() -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(self),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    /// Decode from JSON string
    public static func fromJSONString(_ json: String) -> SessionEvent? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SessionEvent.self, from: data)
    }
}
