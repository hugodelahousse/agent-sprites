import AgentSpritesCore
import Foundation

/// macOS IPC provider using DistributedNotificationCenter
final class MacIPCProvider: IPCProvider, @unchecked Sendable {
    private var eventObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?

    func postSessionEvent(_ event: SessionEvent) throws {
        guard let eventJSON = event.toJSONString() else {
            throw IPCError.encodingFailed
        }

        DistributedNotificationCenter.default().postNotificationName(
            AgentSpritesConstants.sessionEventNotification,
            object: nil,
            userInfo: ["eventJSON": eventJSON],
            deliverImmediately: true
        )
    }

    func postSessionEnd(sessionId: String) throws {
        DistributedNotificationCenter.default().postNotificationName(
            AgentSpritesConstants.sessionEndNotification,
            object: nil,
            userInfo: ["sessionId": sessionId],
            deliverImmediately: true
        )
    }

    func observeEvents(
        onSessionEvent: @escaping @Sendable (SessionEvent) -> Void,
        onSessionEnd: @escaping @Sendable (String) -> Void
    ) {
        eventObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionEventNotification,
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo
            guard let userInfo,
                  let eventJSON = userInfo["eventJSON"] as? String,
                  let event = SessionEvent.fromJSONString(eventJSON) else {
                return
            }
            onSessionEvent(event)
        }

        endObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionEndNotification,
            object: nil,
            queue: .main
        ) { notification in
            let userInfo = notification.userInfo
            guard let userInfo,
                  let sessionId = userInfo["sessionId"] as? String else {
                return
            }
            onSessionEnd(sessionId)
        }
    }

    func stopObserving() {
        if let eventObserver {
            DistributedNotificationCenter.default().removeObserver(eventObserver)
            self.eventObserver = nil
        }
        if let endObserver {
            DistributedNotificationCenter.default().removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    deinit {
        stopObserving()
    }
}

enum IPCError: Error {
    case encodingFailed
}
