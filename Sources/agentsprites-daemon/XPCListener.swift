import Foundation
import AgentSpritesCore

/// Handles XPC connections and implements the daemon protocol
final class XPCServiceDelegate: NSObject, NSXPCListenerDelegate {
    let sessionManager: SessionManager

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = createDaemonInterface()
        newConnection.exportedObject = XPCHandler(sessionManager: sessionManager)
        newConnection.resume()
        return true
    }
}

/// Implements the XPC protocol methods
final class XPCHandler: NSObject, AgentSpritesDaemonProtocol {
    let sessionManager: SessionManager

    init(sessionManager: SessionManager) {
        self.sessionManager = sessionManager
        super.init()
    }

    func updateSession(_ request: SessionUpdateRequest, reply: @escaping (Bool) -> Void) {
        Task {
            let success = await sessionManager.updateSession(request)
            reply(success)
        }
    }

    func getAllSessions(reply: @escaping (Data?) -> Void) {
        Task {
            let data = await sessionManager.getSessionsData()
            reply(data)
        }
    }

    func registerClient(_ endpoint: NSXPCListenerEndpoint) {
        // No longer used - updates via DistributedNotificationCenter
    }

    func unregisterClient() {
        // No longer used
    }

    func ping(reply: @escaping (Bool) -> Void) {
        reply(true)
    }
}
