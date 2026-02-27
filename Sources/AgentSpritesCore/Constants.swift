import Foundation

public enum AgentSpritesConstants {
    /// Duration in seconds before transitioning from done to idle
    public static let doneToIdleDelay: TimeInterval = 5.0

    /// Notification name for session events from CLI (DistributedNotificationCenter)
    /// Payload contains JSON-encoded SessionEvent in "eventJSON" key
    public static let sessionEventNotification = Notification.Name("com.agentsprites.sessionEvent")

    /// Notification name for session removal (DistributedNotificationCenter)
    /// Payload contains session ID in "sessionId" key
    public static let sessionEndNotification = Notification.Name("com.agentsprites.sessionEnd")

    // MARK: - Paths

    /// Base directory for all AgentSprites data (~/Library/Application Support/AgentSprites)
    public static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AgentSprites")
    }

    /// Directory for character packs
    public static var charactersDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Characters")
    }
}
