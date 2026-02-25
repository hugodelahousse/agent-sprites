import Foundation
import AgentSpritesCore

// Create session manager
let sessionManager = SessionManager()

// Create XPC listener delegate
let delegate = XPCServiceDelegate(sessionManager: sessionManager)

// Create and configure XPC listener for Mach service
let listener = NSXPCListener(machServiceName: AgentSpritesConstants.xpcServiceName)
listener.delegate = delegate
listener.resume()

// Log startup
NSLog("AgentSprites daemon started, listening on \(AgentSpritesConstants.xpcServiceName)")

// Run the main run loop
RunLoop.main.run()
