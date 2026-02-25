import Foundation

/// XPC Protocol for communication between CLI/App and the daemon
/// Must be @objc for NSXPCInterface compatibility
@objc public protocol AgentSpritesDaemonProtocol {
    /// Update a session's state based on a hook event
    /// - Parameters:
    ///   - sessionId: The unique session identifier
    ///   - eventName: The hook event name (e.g., "SessionStart", "UserPromptSubmit")
    ///   - workingDirectory: The current working directory of the session
    ///   - tty: The TTY device path for terminal focusing (optional)
    ///   - bundleId: The app bundle ID for activation (optional)
    ///   - summary: Session summary from Claude Code (optional)
    ///   - gitBranch: Git branch name (optional)
    ///   - reply: Callback with success status
    func updateSession(
        sessionId: String,
        eventName: String,
        workingDirectory: String,
        tty: String?,
        bundleId: String?,
        summary: String?,
        gitBranch: String?,
        reply: @escaping (Bool) -> Void
    )

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
    return NSXPCInterface(with: AgentSpritesDaemonProtocol.self)
}

/// Helper to create XPC interface for the client protocol
public func createClientInterface() -> NSXPCInterface {
    return NSXPCInterface(with: AgentSpritesClientProtocol.self)
}
