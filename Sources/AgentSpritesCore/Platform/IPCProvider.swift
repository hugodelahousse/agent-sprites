import Foundation

/// Abstracts inter-process communication between CLI and App.
/// macOS uses DistributedNotificationCenter; Windows will use named pipes or sockets.
public protocol IPCProvider: Sendable {
    /// Post a session event (CLI → App)
    func postSessionEvent(_ event: SessionEvent) throws

    /// Post a session end notification (CLI → App)
    func postSessionEnd(sessionId: String) throws

    /// Start observing events (App side)
    func observeEvents(
        onSessionEvent: @escaping @Sendable (SessionEvent) -> Void,
        onSessionEnd: @escaping @Sendable (String) -> Void
    )

    /// Stop observing events
    func stopObserving()
}
