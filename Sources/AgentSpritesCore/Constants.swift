import Foundation

public enum AgentSpritesConstants {
    public static let xpcServiceName = "com.agentsprites.xpc"

    /// Duration in seconds before transitioning from done to idle
    public static let doneToIdleDelay: TimeInterval = 5.0

    /// Notification name for session updates (DistributedNotificationCenter)
    public static let sessionsDidChangeNotification = Notification.Name("com.agentsprites.sessionsDidChange")
}
