import AppKit
import CoreGraphics

/// Observes window positions on screen to provide ledges for blobs to walk on
@MainActor
final class WindowObserver {
    static let shared = WindowObserver()

    /// Represents a ledge (top edge of a window) that blobs can walk on
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

    /// Represents a window rectangle for occlusion testing
    private struct WindowRect {
        let minX: CGFloat
        let maxX: CGFloat
        let minY: CGFloat  // Bottom in Cocoa coords
        let maxY: CGFloat  // Top in Cocoa coords

        func coversTopEdge(of other: WindowRect, tolerance: CGFloat = 5) -> Bool {
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
    private var lastUpdate: Date = .distantPast
    private let updateInterval: TimeInterval = 0.5  // Update every 500ms

    /// Get all ledges (window tops) sorted by Y position (highest first)
    func getLedges() -> [Ledge] {
        let now = Date()
        if now.timeIntervalSince(lastUpdate) > updateInterval {
            updateLedges()
            lastUpdate = now
        }
        return cachedLedges
    }

    private func updateLedges() {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            cachedLedges = []
            return
        }

        // Get our own process ID to exclude our windows
        let ourPid = ProcessInfo.processInfo.processIdentifier

        guard let screen = NSScreen.main else {
            cachedLedges = []
            return
        }
        let screenHeight = screen.frame.height

        // Collect valid windows with their rects (in front-to-back order)
        var windowRects: [(rect: WindowRect, windowId: CGWindowID)] = []

        for windowInfo in windowList {
            guard let boundsDict = windowInfo[kCGWindowBounds as String] as? [String: CGFloat],
                  let windowId = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  windowInfo[kCGWindowOwnerName as String] as? String != nil else {
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

    /// Find the ledge at or below a given position that the blob can land on
    func findLedgeBelow(position: CGPoint, currentLedgeY: CGFloat?) -> Ledge? {
        let ledges = getLedges()

        // Find the highest ledge that is below the blob's current Y
        // and that the blob is horizontally within
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

    /// Find the ledge the blob is currently standing on
    func findCurrentLedge(position: CGPoint, tolerance: CGFloat = 5) -> Ledge? {
        let ledges = getLedges()

        for ledge in ledges {
            // Check if blob is at this ledge's Y level
            if abs(position.y - ledge.y) < tolerance {
                // Check if horizontally within ledge
                if ledge.contains(x: position.x) {
                    return ledge
                }
            }
        }

        return nil
    }
}
