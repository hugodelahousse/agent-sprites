import Foundation

// swiftlint:disable legacy_objc_type

/// Data object for session updates, compatible with XPC via NSSecureCoding
@objc public final class SessionUpdateRequest: NSObject, NSSecureCoding {
    public static var supportsSecureCoding: Bool { true }

    @objc public let sessionId: String
    @objc public let eventName: String
    @objc public let workingDirectory: String
    @objc public let tty: String?
    @objc public let bundleId: String?
    @objc public let summary: String?
    @objc public let gitBranch: String?
    @objc public let notificationType: String?

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
        super.init()
    }

    public required init?(coder: NSCoder) {
        guard let sessionId = coder.decodeObject(of: NSString.self, forKey: "sessionId") as String?,
              let eventName = coder.decodeObject(of: NSString.self, forKey: "eventName") as String?,
              let workingDirectory = coder.decodeObject(of: NSString.self, forKey: "workingDirectory") as String? else {
            return nil
        }
        self.sessionId = sessionId
        self.eventName = eventName
        self.workingDirectory = workingDirectory
        self.tty = coder.decodeObject(of: NSString.self, forKey: "tty") as String?
        self.bundleId = coder.decodeObject(of: NSString.self, forKey: "bundleId") as String?
        self.summary = coder.decodeObject(of: NSString.self, forKey: "summary") as String?
        self.gitBranch = coder.decodeObject(of: NSString.self, forKey: "gitBranch") as String?
        self.notificationType = coder.decodeObject(of: NSString.self, forKey: "notificationType") as String?
        super.init()
    }

    public func encode(with coder: NSCoder) {
        coder.encode(sessionId as NSString, forKey: "sessionId")
        coder.encode(eventName as NSString, forKey: "eventName")
        coder.encode(workingDirectory as NSString, forKey: "workingDirectory")
        coder.encode(tty as NSString?, forKey: "tty")
        coder.encode(bundleId as NSString?, forKey: "bundleId")
        coder.encode(summary as NSString?, forKey: "summary")
        coder.encode(gitBranch as NSString?, forKey: "gitBranch")
        coder.encode(notificationType as NSString?, forKey: "notificationType")
    }
}

// swiftlint:enable legacy_objc_type

/// XPC Protocol for communication between CLI/App and the daemon
/// Must be @objc for NSXPCInterface compatibility
@objc public protocol AgentSpritesDaemonProtocol {
    /// Update a session's state based on a hook event
    /// - Parameters:
    ///   - request: The session update request containing all parameters
    ///   - reply: Callback with success status
    func updateSession(_ request: SessionUpdateRequest, reply: @escaping (Bool) -> Void)

    /// Get all current session states
    /// - Parameter reply: Callback with JSON-encoded session states
    func getAllSessions(reply: @escaping (Data?) -> Void)

    /// Register a client for session update notifications
    /// - Parameter endpoint: The client's listener endpoint for callbacks
    func registerClient(_ endpoint: NSXPCListenerEndpoint)

    /// Unregister a client from session update notifications
    func unregisterClient()

    /// Ping to check if daemon is alive
    /// - Parameter reply: Callback confirming daemon is responsive
    func ping(reply: @escaping (Bool) -> Void)
}

/// Protocol for callbacks from daemon to registered clients (App)
@objc public protocol AgentSpritesClientProtocol {
    /// Called when any session state changes
    /// - Parameter sessionsData: JSON-encoded SessionStore
    func sessionsDidUpdate(_ sessionsData: Data)
}

/// Helper to create XPC interface for the daemon protocol
public func createDaemonInterface() -> NSXPCInterface {
    let interface = NSXPCInterface(with: AgentSpritesDaemonProtocol.self)
    // Allow SessionUpdateRequest to be passed across XPC
    // swiftlint:disable:next force_cast legacy_objc_type
    let allowedClasses = NSSet(objects: SessionUpdateRequest.self, NSString.self) as! Set<AnyHashable>
    interface.setClasses(
        allowedClasses,
        for: #selector(AgentSpritesDaemonProtocol.updateSession(_:reply:)),
        argumentIndex: 0,
        ofReply: false
    )
    return interface
}

/// Helper to create XPC interface for the client protocol
public func createClientInterface() -> NSXPCInterface {
    NSXPCInterface(with: AgentSpritesClientProtocol.self)
}
