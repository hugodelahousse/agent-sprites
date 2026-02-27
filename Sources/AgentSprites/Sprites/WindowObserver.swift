import AppKit
import CoreGraphics
import QuartzCore

/// Observes window positions on screen to provide ledges for sprites to walk on
@MainActor
final class WindowObserver {
    static let shared = WindowObserver()

    /// Represents a ledge (top edge of a window) that sprites can walk on
    struct Ledge: Sendable {
        let minX: CGFloat
        let maxX: CGFloat
        let y: CGFloat
        let windowId: CGWindowID

        var width: CGFloat { maxX - minX }

        func contains(x: CGFloat, margin: CGFloat = 20) -> Bool {
            x >= (minX - margin) && x <= (maxX + margin)
        }
    }

    /// Represents a wall (vertical edge of a window) that sprites can climb
    struct Wall: Sendable {
        enum Side: Sendable { case left, right }

        let x: CGFloat          // X position of the wall
        let minY: CGFloat       // Bottom of climbable range (Cocoa coords)
        let maxY: CGFloat       // Top of climbable range (window top)
        let side: Side          // Left or right edge of window
        let windowId: CGWindowID

        func contains(y: CGFloat, margin: CGFloat = 20) -> Bool {
            y >= (minY - margin) && y <= (maxY + margin)
        }
    }

    /// Represents a window rectangle for occlusion testing
    private struct WindowRect {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat  // Bottom in Cocoa coords
        let maxY: CGFloat  // Top in Cocoa coords

        func coversTopEdge(of other: Self, tolerance: CGFloat = 5) -> Bool {
            // Check if this window covers the top edge of another window
            // The other window's top edge is at other.maxY
            // This window covers it if this window's vertical range includes that Y
            // and horizontal ranges overlap
            let verticalOverlap = minY < other.maxY && maxY > other.maxY - tolerance
            let horizontalOverlap = minX < other.maxX && maxX > other.minX
            return verticalOverlap && horizontalOverlap
        }

        /// Returns the horizontal range of the top edge that is NOT covered by this window
        func uncoveredSegments(topEdgeMinX: CGFloat, topEdgeMaxX: CGFloat, topEdgeY: CGFloat) -> [(CGFloat, CGFloat)] {
            // If this window doesn't cover the Y level, the whole edge is uncovered
            if maxY <= topEdgeY || minY >= topEdgeY + 5 {
                return [(topEdgeMinX, topEdgeMaxX)]
            }

            // If no horizontal overlap, whole edge is uncovered
            if maxX <= topEdgeMinX || minX >= topEdgeMaxX {
                return [(topEdgeMinX, topEdgeMaxX)]
            }

            // Calculate uncovered segments
            var segments: [(CGFloat, CGFloat)] = []

            // Left uncovered portion
            if minX > topEdgeMinX {
                segments.append((topEdgeMinX, minX))
            }

            // Right uncovered portion
            if maxX < topEdgeMaxX {
                segments.append((maxX, topEdgeMaxX))
            }

            return segments
        }
    }

    private var cachedLedges: [Ledge] = []
    private var cachedWalls: [Wall] = []
    private var lastUpdateTime: CFTimeInterval = 0
    private let updateInterval: CFTimeInterval = 0.5  // Update every 500ms

    /// Get all ledges (window tops) sorted by Y position (highest first)
    func getLedges() -> [Ledge] {
        let now = CACurrentMediaTime()
        if now - lastUpdateTime > updateInterval {
            updateSurfaces()
            lastUpdateTime = now
        }
        return cachedLedges
    }

    /// Get all walls (window edges) for climbing
    func getWalls() -> [Wall] {
        let now = CACurrentMediaTime()
        if now - lastUpdateTime > updateInterval {
            updateSurfaces()
            lastUpdateTime = now
        }
        return cachedWalls
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func updateSurfaces() {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            cachedLedges = []
            cachedWalls = []
            return
        }

        // Get our own process ID to exclude our windows
        let ourPid = ProcessInfo.processInfo.processIdentifier

        // Use the primary screen height for CGWindow coordinate conversion
        // CGWindow bounds always use primary screen as origin reference
        guard let primaryScreen = NSScreen.screens.first else {
            cachedLedges = []
            cachedWalls = []
            return
        }
        let screenHeight = primaryScreen.frame.height
        let groundY = primaryScreen.visibleFrame.minY

        // Collect valid windows with their rects (in front-to-back order)
        var windowRects: [(rect: WindowRect, windowId: CGWindowID)] = []

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowId = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  windowInfo[kCGWindowOwnerName as String] is String else {
                continue
            }

            // Skip our own windows (by PID - more reliable than bundle ID)
            if let ownerPid = windowInfo[kCGWindowOwnerPID as String] as? Int32 {
                if ownerPid == ourPid {
                    continue
                }
            }

            // Get owner name for filtering
            let ownerName = windowInfo[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = windowInfo[kCGWindowName as String] as? String ?? ""

            // Skip system UI elements
            let systemApps = ["Window Server", "Control Center", "Dock", "SystemUIServer", "Notification Center"]
            if systemApps.contains(ownerName) {
                continue
            }

            // Skip iTerm hotkey windows (they're overlay windows)
            if ownerName == "iTerm2" && windowName.contains("Hotkey") {
                continue
            }

            // Skip high layer windows (menu bar items, overlays, etc)
            let layer = windowInfo[kCGWindowLayer as String] as? Int32 ?? 0
            if layer > 23 || layer < 0 {
                continue
            }

            guard let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"] else {
                continue
            }

            // Skip very small windows
            if width < 100 || height < 50 {
                continue
            }

            // Convert to Cocoa coordinates (origin at bottom-left)
            let windowTop = screenHeight - y
            let windowBottom = screenHeight - y - height

            let rect = WindowRect(
                minX: x,
                maxX: x + width,
                minY: windowBottom,
                maxY: windowTop
            )

            windowRects.append((rect, windowId))
        }

        // Now process windows and create ledges, accounting for occlusion
        // Windows are in front-to-back order, so earlier windows occlude later ones
        var ledges: [Ledge] = []

        for (index, current) in windowRects.enumerated() {
            // Start with the full top edge as potentially visible
            var visibleSegments: [(minX: CGFloat, maxX: CGFloat)] = [(current.rect.minX, current.rect.maxX)]

            // Check against all windows in front (earlier in the list)
            for frontIndex in 0..<index {
                let frontRect = windowRects[frontIndex].rect

                // Check if front window occludes any of our visible segments
                var newSegments: [(CGFloat, CGFloat)] = []

                for segment in visibleSegments {
                    // Get the parts of this segment not covered by the front window
                    let uncovered = subtractHorizontalRange(
                        segment: segment,
                        blocker: (frontRect.minX, frontRect.maxX),
                        segmentY: current.rect.maxY,
                        blockerMinY: frontRect.minY,
                        blockerMaxY: frontRect.maxY
                    )
                    newSegments.append(contentsOf: uncovered)
                }

                visibleSegments = newSegments
            }

            // Create ledges for visible segments (filter out tiny segments)
            for segment in visibleSegments {
                let width = segment.maxX - segment.minX
                if width >= 60 {  // Minimum ledge width
                    ledges.append(Ledge(
                        minX: segment.minX,
                        maxX: segment.maxX,
                        y: current.rect.maxY,
                        windowId: current.windowId
                    ))
                }
            }
        }

        // Sort by Y position (highest first) so we check top ledges first
        cachedLedges = ledges.sorted { $0.y > $1.y }

        // Generate walls from window edges
        var walls: [Wall] = []

        for (index, current) in windowRects.enumerated() {
            let rect = current.rect
            let windowId = current.windowId

            // Wall minY should be the window's bottom edge (not extend below the window)
            // But if there's a surface above the window bottom, use that instead
            let windowBottom = rect.minY
            let surfaceBelowLeft = findSurfaceBelow(atX: rect.minX, belowY: rect.maxY, ledges: cachedLedges, groundY: groundY)
            let surfaceBelowRight = findSurfaceBelow(atX: rect.maxX, belowY: rect.maxY, ledges: cachedLedges, groundY: groundY)
            // Take the higher of window bottom or surface below
            let leftWallMinY = max(windowBottom, surfaceBelowLeft)
            let rightWallMinY = max(windowBottom, surfaceBelowRight)

            // Check for occlusion by windows in front
            // A wall is occluded if a front window covers its X position
            var leftWallVisible = true
            var rightWallVisible = true

            for frontIndex in 0..<index {
                let frontRect = windowRects[frontIndex].rect

                // Left wall is occluded if front window's horizontal range covers minX
                // and front window's vertical range overlaps with the wall's range
                if frontRect.minX <= rect.minX && frontRect.maxX > rect.minX {
                    if frontRect.minY < rect.maxY && frontRect.maxY > leftWallMinY {
                        leftWallVisible = false
                    }
                }

                // Right wall is occluded if front window's horizontal range covers maxX
                if frontRect.minX < rect.maxX && frontRect.maxX >= rect.maxX {
                    if frontRect.minY < rect.maxY && frontRect.maxY > rightWallMinY {
                        rightWallVisible = false
                    }
                }
            }

            // Minimum wall height to be useful
            let minWallHeight: CGFloat = 50

            if leftWallVisible && (rect.maxY - leftWallMinY) >= minWallHeight {
                walls.append(Wall(
                    x: rect.minX,
                    minY: leftWallMinY,
                    maxY: rect.maxY,
                    side: .left,
                    windowId: windowId
                ))
            }

            if rightWallVisible && (rect.maxY - rightWallMinY) >= minWallHeight {
                walls.append(Wall(
                    x: rect.maxX,
                    minY: rightWallMinY,
                    maxY: rect.maxY,
                    side: .right,
                    windowId: windowId
                ))
            }
        }

        cachedWalls = walls
    }

    /// Find the highest surface (ledge or ground) at a given X position below a given Y
    private func findSurfaceBelow(atX x: CGFloat, belowY: CGFloat, ledges: [Ledge], groundY: CGFloat) -> CGFloat {
        var highestY = groundY

        for ledge in ledges {
            // Ledge must be below our starting point
            guard ledge.y < belowY else { continue }

            // Check if this X is within the ledge bounds (with margin)
            guard ledge.contains(x: x, margin: 10) else { continue }

            // Take the highest one
            if ledge.y > highestY {
                highestY = ledge.y
            }
        }

        return highestY
    }

    /// Subtract a blocking horizontal range from a segment, considering Y overlap
    private func subtractHorizontalRange(
        segment: (minX: CGFloat, maxX: CGFloat),
        blocker: (minX: CGFloat, maxX: CGFloat),
        segmentY: CGFloat,
        blockerMinY: CGFloat,
        blockerMaxY: CGFloat
    ) -> [(minX: CGFloat, maxX: CGFloat)] {
        // If blocker doesn't cover this Y level, segment is unchanged
        // The blocker covers segmentY if blockerMinY <= segmentY <= blockerMaxY
        if blockerMaxY <= segmentY || blockerMinY > segmentY {
            return [segment]
        }

        // If no horizontal overlap, segment is unchanged
        if blocker.maxX <= segment.minX || blocker.minX >= segment.maxX {
            return [segment]
        }

        // Calculate remaining segments after subtraction
        var result: [(CGFloat, CGFloat)] = []

        // Left remainder
        if blocker.minX > segment.minX {
            result.append((segment.minX, blocker.minX))
        }

        // Right remainder
        if blocker.maxX < segment.maxX {
            result.append((blocker.maxX, segment.maxX))
        }

        return result
    }

    /// Find the ledge at or below a given position that the sprite can land on
    func findLedgeBelow(position: CGPoint, currentLedgeY: CGFloat?) -> Ledge? {
        let ledges = getLedges()

        // Find the highest ledge that is below the sprite's current Y
        // and that the sprite is horizontally within
        for ledge in ledges {
            // Must be at or below current position
            if ledge.y >= position.y - 5 {
                continue
            }

            // Skip if this is the ledge we're already on
            if let currentY = currentLedgeY, abs(ledge.y - currentY) < 5 {
                continue
            }

            // Must be horizontally within ledge bounds
            if ledge.contains(x: position.x) {
                return ledge
            }
        }

        return nil
    }

    /// Find the ledge the sprite is currently standing on
    func findCurrentLedge(position: CGPoint, tolerance: CGFloat = 5) -> Ledge? {
        let ledges = getLedges()

        for ledge in ledges where abs(position.y - ledge.y) < tolerance {
            // Check if horizontally within ledge
            if ledge.contains(x: position.x) {
                return ledge
            }
        }

        return nil
    }
}
