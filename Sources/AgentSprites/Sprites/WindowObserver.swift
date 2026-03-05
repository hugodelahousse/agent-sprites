import AppKit
import ApplicationServices
import CoreGraphics
import os
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
    }

    /// Sorted, non-overlapping set of horizontal intervals
    private struct IntervalSet {
        private(set) var intervals: [(min: CGFloat, max: CGFloat)] = []

        /// Merge [lo, hi] into the existing sorted intervals. O(k).
        mutating func insert(_ lo: CGFloat, _ hi: CGFloat) {
            guard lo < hi else { return }

            var merged = (min: lo, max: hi)
            var result: [(min: CGFloat, max: CGFloat)] = []
            var inserted = false

            for iv in intervals {
                if iv.max < merged.min {
                    // iv entirely before merged
                    result.append(iv)
                } else if iv.min > merged.max {
                    // iv entirely after merged — flush merged first
                    if !inserted {
                        result.append(merged)
                        inserted = true
                    }
                    result.append(iv)
                } else {
                    // Overlapping — extend merged
                    merged.min = Swift.min(merged.min, iv.min)
                    merged.max = Swift.max(merged.max, iv.max)
                }
            }

            if !inserted {
                result.append(merged)
            }

            intervals = result
        }

        /// Return parts of [lo, hi] NOT covered by any interval. O(k).
        func uncovered(in lo: CGFloat, to hi: CGFloat) -> [(CGFloat, CGFloat)] {
            guard lo < hi else { return [] }
            var result: [(CGFloat, CGFloat)] = []
            var cursor = lo

            for iv in intervals {
                if iv.min >= hi { break }
                if iv.max <= cursor { continue }

                let gapStart = cursor
                let gapEnd = Swift.min(iv.min, hi)
                if gapEnd > gapStart {
                    result.append((gapStart, gapEnd))
                }
                cursor = Swift.max(cursor, iv.max)
                if cursor >= hi { break }
            }

            if cursor < hi {
                result.append((cursor, hi))
            }

            return result
        }

        /// Point query via binary search. O(log k).
        func covers(_ x: CGFloat) -> Bool {
            var lo = 0
            var hi = intervals.count - 1

            while lo <= hi {
                let mid = (lo + hi) / 2
                let iv = intervals[mid]
                if x < iv.min {
                    hi = mid - 1
                } else if x > iv.max {
                    lo = mid + 1
                } else {
                    return true
                }
            }

            return false
        }
    }

    /// Y-range stabbing index: stores rects sorted by minY for efficient queries
    private struct RectIndex {
        private var rects: [WindowRect] = []

        /// Insert a rect, maintaining sort by minY. O(log n) search + O(n) shift.
        mutating func insert(_ rect: WindowRect) {
            // Binary search for insertion point
            var lo = 0
            var hi = rects.count

            while lo < hi {
                let mid = (lo + hi) / 2
                if rects[mid].minY < rect.minY {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            rects.insert(rect, at: lo)
        }

        /// Return all rects where minY <= y <= maxY. O(log n + scan).
        func query(y: CGFloat) -> [WindowRect] {
            guard !rects.isEmpty else { return [] }

            // Binary search for first rect with minY > y — all candidates are before this
            var lo = 0
            var hi = rects.count

            while lo < hi {
                let mid = (lo + hi) / 2
                if rects[mid].minY <= y {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }

            // lo = first index where minY > y, so candidates are 0..<lo
            var result: [WindowRect] = []
            for i in 0..<lo where rects[i].maxY >= y {
                result.append(rects[i])
            }

            return result
        }
    }

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "WindowObserver")
    private let accessibilityWatcher = AccessibilityWindowWatcher()
    private let axPollingInterval: CFTimeInterval = 3.0

    private var cachedLedges: [Ledge] = []
    private var cachedWalls: [Wall] = []
    private var lastUpdateTime: CFTimeInterval = 0
    private var updateInterval: CFTimeInterval = 0.5  // Update every 500ms (reduced when AX active)

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

    /// Notification posted when window layout changes are detected via AXObserver
    static let windowsDidChangeNotification = Notification.Name("WindowObserverWindowsDidChange")

    /// Invalidate the cache so the next getLedges/getWalls call recomputes immediately
    func invalidateCache() {
        lastUpdateTime = 0
        NotificationCenter.default.post(name: Self.windowsDidChangeNotification, object: nil)
    }

    /// Start AXObserver-based watching if accessibility is granted.
    /// When active, polling interval increases to 3s (AX events trigger immediate invalidation).
    /// Without accessibility, keeps the default 500ms polling — zero regression.
    func startObserving() {
        accessibilityWatcher.onWindowsChanged = { [weak self] in
            self?.invalidateCache()
        }

        if AXIsProcessTrusted() {
            accessibilityWatcher.start()
            updateInterval = axPollingInterval
            logger.info("AXObserver active — polling interval set to \(self.axPollingInterval, privacy: .public)s")
        } else {
            logger.info("Accessibility not granted — using \(self.updateInterval, privacy: .public)s polling")
        }
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

        // Single front-to-back pass: compute ledges and walls using interval index
        var rectIndex = RectIndex()
        var ledges: [Ledge] = []
        var walls: [Wall] = []

        for current in windowRects {
            let rect = current.rect
            let topY = rect.maxY

            // Query all front rects that span this window's top edge Y
            let frontRects = rectIndex.query(y: topY)

            // Build X-coverage from front rects
            var coverage = IntervalSet()
            for frontRect in frontRects {
                coverage.insert(frontRect.minX, frontRect.maxX)
            }

            // Compute visible ledge segments
            let visible = coverage.uncovered(in: rect.minX, to: rect.maxX)
            for segment in visible where (segment.1 - segment.0) >= 60 {
                ledges.append(Ledge(
                    minX: segment.0,
                    maxX: segment.1,
                    y: topY,
                    windowId: current.windowId
                ))
            }

            // Compute walls — check if left/right edges are covered
            let windowBottom = rect.minY
            let surfaceBelowLeft = findSurfaceBelow(atX: rect.minX, belowY: topY, ledges: ledges, groundY: groundY)
            let surfaceBelowRight = findSurfaceBelow(atX: rect.maxX, belowY: topY, ledges: ledges, groundY: groundY)
            let leftWallMinY = max(windowBottom, surfaceBelowLeft)
            let rightWallMinY = max(windowBottom, surfaceBelowRight)

            let minWallHeight: CGFloat = 50
            let leftCovered = coverage.covers(rect.minX)
            let rightCovered = coverage.covers(rect.maxX)

            if !leftCovered && (topY - leftWallMinY) >= minWallHeight {
                walls.append(Wall(
                    x: rect.minX,
                    minY: leftWallMinY,
                    maxY: topY,
                    side: .left,
                    windowId: current.windowId
                ))
            }

            if !rightCovered && (topY - rightWallMinY) >= minWallHeight {
                walls.append(Wall(
                    x: rect.maxX,
                    minY: rightWallMinY,
                    maxY: topY,
                    side: .right,
                    windowId: current.windowId
                ))
            }

            // Insert this window into index for future queries
            rectIndex.insert(rect)
        }

        // Sort by Y position (highest first) so we check top ledges first
        cachedLedges = ledges.sorted { $0.y > $1.y }
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
