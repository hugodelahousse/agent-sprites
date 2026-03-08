import os

/// Signpost logs for profiling with Instruments
enum AppSignposts {
    #if DEBUG
        static let renderLoop = OSLog(subsystem: "com.agentsprites.app", category: "RenderLoop")
        static let sessionProcessing = OSLog(subsystem: "com.agentsprites.app", category: "SessionProcessing")
        static let textureCache = OSLog(subsystem: "com.agentsprites.app", category: "TextureCache")
    #else
        static let renderLoop = OSLog.disabled
        static let sessionProcessing = OSLog.disabled
        static let textureCache = OSLog.disabled
    #endif
}
