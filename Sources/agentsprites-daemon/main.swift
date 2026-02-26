import Foundation
import AgentSpritesCore
import os.log

private let logger = Logger(subsystem: "com.agentsprites.daemon", category: "main")

// Create session manager
let sessionManager = SessionManager()

// Create XPC listener delegate
let delegate = XPCServiceDelegate(sessionManager: sessionManager)

// Create and configure XPC listener for Mach service
let listener = NSXPCListener(machServiceName: AgentSpritesConstants.xpcServiceName)
listener.delegate = delegate
listener.resume()

// Log startup
logger.info("Daemon started, listening on \(AgentSpritesConstants.xpcServiceName, privacy: .public)")

// Run the main run loop
RunLoop.main.run()
