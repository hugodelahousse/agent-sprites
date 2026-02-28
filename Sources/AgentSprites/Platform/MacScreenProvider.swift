import AgentSpritesCore
import AppKit
import CoreGraphics

/// macOS screen provider using NSScreen + CGWindowListCopyWindowInfo
final class MacScreenProvider: ScreenProvider, @unchecked Sendable {
    func getAllDisplays() -> [DisplayInfo] {
        NSScreen.screens.enumerated().map { index, screen in
            DisplayInfo(
                id: "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? index)",
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isPrimary: index == 0
            )
        }
    }

    func getDisplay(containing point: CGPoint) -> DisplayInfo? {
        for (index, screen) in NSScreen.screens.enumerated() {
            if screen.frame.contains(point) {
                return DisplayInfo(
                    id: "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? index)",
                    frame: screen.frame,
                    visibleFrame: screen.visibleFrame,
                    isPrimary: index == 0
                )
            }
        }
        // Fallback to primary
        return getPrimaryDisplay()
    }

    func getPrimaryDisplay() -> DisplayInfo? {
        guard let screen = NSScreen.screens.first else { return nil }
        return DisplayInfo(
            id: "\(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] ?? 0)",
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            isPrimary: true
        )
    }

    func getVisibleWindows() -> [ExternalWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        let ourPid = ProcessInfo.processInfo.processIdentifier
        guard let primaryScreen = NSScreen.screens.first else { return [] }
        let screenHeight = primaryScreen.frame.height

        var results: [ExternalWindowInfo] = []

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowId = windowInfo[kCGWindowNumber as String] as? UInt32 else {
                continue
            }

            let ownerPid = windowInfo[kCGWindowOwnerPID as String] as? Int32 ?? 0
            if ownerPid == ourPid { continue }

            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String
            let layer = windowInfo[kCGWindowLayer as String] as? Int32 ?? 0

            // Skip system UI and invalid layers
            let systemApps = ["Window Server", "Control Center", "Dock", "SystemUIServer", "Notification Center"]
            if let ownerName, systemApps.contains(ownerName) { continue }
            if layer > 23 || layer < 0 { continue }

            guard let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            if width < 100 || height < 50 { continue }

            // Convert CGWindow coordinates (origin top-left) to Cocoa (origin bottom-left)
            let windowTop = screenHeight - y
            let windowBottom = screenHeight - y - height

            let frame = CGRect(x: x, y: windowBottom, width: width, height: windowTop - windowBottom)

            results.append(ExternalWindowInfo(
                id: windowId,
                frame: frame,
                ownerName: ownerName,
                ownerPID: ownerPid,
                layer: layer
            ))
        }

        return results
    }
}
