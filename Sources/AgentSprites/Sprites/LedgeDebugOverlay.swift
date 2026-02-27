import AgentSpritesCore
import AppKit
import SwiftUI

/// Represents a sprite's bounding box for debug visualization
struct SpriteBounds {
    let sessionId: String
    let position: CGPoint  // Bottom-center of sprite (Cocoa coords)
    let size: CGSize       // 64x64 typically
    let status: SessionStatus?
}

/// Debug overlay that shows ledge positions as lines on all screens
@MainActor
final class LedgeDebugOverlay {
    private var windows: [NSWindow] = []
    private var isVisible = false
    private let windowObserver = WindowObserver.shared
    private var updateTimer: Timer?

    /// Callback to get current sprite bounds from coordinator
    var getSpriteBounds: (() -> [SpriteBounds])?

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }

        // Create windows for each screen if needed
        if windows.isEmpty {
            for screen in screens {
                let window = createWindow(screen: screen)
                windows.append(window)
            }
        }

        // Update positions and show
        for (index, screen) in screens.enumerated() {
            if index < windows.count {
                windows[index].setFrame(screen.frame, display: true)
                windows[index].orderFront(nil)
            }
        }

        isVisible = true

        // Start update timer
        startUpdating()
    }

    func hide() {
        for window in windows {
            window.orderOut(nil)
        }
        isVisible = false
        updateTimer?.invalidate()
        updateTimer = nil
    }

    private func createWindow(screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .screenSaver  // Above menu bar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        window.ignoresMouseEvents = true
        window.hasShadow = false

        return window
    }

    private func startUpdating() {
        updateLedges()

        // Update every 500ms while visible
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isVisible else { return }
                self.updateLedges()
            }
        }
    }

    private func updateLedges() {
        let screens = NSScreen.screens
        let ledges = windowObserver.getLedges()
        let walls = windowObserver.getWalls()
        let spriteBounds = getSpriteBounds?() ?? []

        // Use primary screen height for coordinate conversion (matches CGWindow coords)
        let primaryScreenHeight = screens.first?.frame.height ?? 0

        for (index, screen) in screens.enumerated() {
            guard index < windows.count else { continue }
            let window = windows[index]

            let groundY = screen.visibleFrame.minY

            let view = LedgeDebugView(
                ledges: ledges,
                walls: walls,
                spriteBounds: spriteBounds,
                groundY: groundY,
                screenHeight: primaryScreenHeight,
                screenBounds: screen.visibleFrame,
                screenFrame: screen.frame
            )
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = window.contentView?.bounds ?? screen.frame

            window.contentView = hostingView
        }
    }
}

/// SwiftUI view that draws ledge lines, walls, and sprite bounds
private struct LedgeDebugView: View {
    let ledges: [WindowObserver.Ledge]
    let walls: [WindowObserver.Wall]
    let spriteBounds: [SpriteBounds]
    let groundY: CGFloat
    let screenHeight: CGFloat  // Primary screen height for coordinate conversion
    let screenBounds: CGRect   // This screen's visible frame
    let screenFrame: CGRect    // This screen's full frame

    var body: some View {
        Canvas { context, size in
            // Offset for translating global coordinates to this screen's local coordinates
            let offsetX = screenFrame.minX
            let offsetY = screenFrame.minY

            // Draw canvas bounds (screen.visibleFrame - where sprites can exist)
            // Convert from Cocoa coords (origin bottom-left) to SwiftUI (origin top-left)
            let canvasLeft = screenBounds.minX - offsetX
            let canvasRight = screenBounds.maxX - offsetX
            let canvasBottom = screenHeight - screenBounds.minY - offsetY
            let canvasTop = screenHeight - screenBounds.maxY - offsetY

            let canvasRect = CGRect(
                x: canvasLeft,
                y: canvasTop,
                width: canvasRight - canvasLeft,
                height: canvasBottom - canvasTop
            )
            let canvasPath = Path { path in
                path.addRect(canvasRect)
            }
            context.stroke(canvasPath, with: .color(.white.opacity(0.8)), lineWidth: 2)

            // Label the canvas bounds
            let canvasLabel = Text("SPRITE CANVAS").font(.system(size: 10, weight: .bold, design: .monospaced))
            context.draw(canvasLabel, at: CGPoint(x: canvasLeft + 5, y: canvasTop + 14))

            // Draw ground line (relative to this screen)
            let groundYLocal = screenHeight - groundY - offsetY
            let groundPath = Path { path in
                path.move(to: CGPoint(x: 0, y: groundYLocal))
                path.addLine(to: CGPoint(x: size.width, y: groundYLocal))
            }
            context.stroke(groundPath, with: .color(.green.opacity(0.8)), lineWidth: 2)

            // Draw ground label
            let groundText = Text("GROUND").font(.system(size: 10, weight: .bold, design: .monospaced))
            context.draw(groundText, at: CGPoint(x: 50, y: groundYLocal - 12))

            // Draw ledge lines (cyan/pink horizontal)
            for (index, ledge) in ledges.enumerated() {
                // Convert from Cocoa coordinates (origin bottom-left) to SwiftUI (origin top-left)
                let y = screenHeight - ledge.y - offsetY
                let minX = ledge.minX - offsetX
                let maxX = ledge.maxX - offsetX

                // Skip if not visible on this screen
                if maxX < 0 || minX > size.width || y < 0 || y > size.height {
                    continue
                }

                let ledgePath = Path { path in
                    path.move(to: CGPoint(x: minX, y: y))
                    path.addLine(to: CGPoint(x: maxX, y: y))
                }

                // Alternate colors for visibility
                let color: Color = index.isMultiple(of: 2) ? .cyan : .pink
                context.stroke(ledgePath, with: .color(color.opacity(0.8)), lineWidth: 2)

                // Draw ledge info
                let label = Text("L\(index) y=\(Int(ledge.y))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color)
                context.draw(label, at: CGPoint(x: minX + 5, y: y - 12))
            }

            // Draw walls (orange vertical lines)
            for (index, wall) in walls.enumerated() {
                // Convert from Cocoa coordinates to SwiftUI
                let x = wall.x - offsetX
                let topY = screenHeight - wall.maxY - offsetY
                let bottomY = screenHeight - wall.minY - offsetY

                // Skip if not visible on this screen
                if x < 0 || x > size.width || bottomY < 0 || topY > size.height {
                    continue
                }

                let wallPath = Path { path in
                    path.move(to: CGPoint(x: x, y: topY))
                    path.addLine(to: CGPoint(x: x, y: bottomY))
                }

                context.stroke(wallPath, with: .color(.orange.opacity(0.8)), lineWidth: 2)

                // Draw wall info
                let sideLabel = wall.side == .left ? "L" : "R"
                let label = Text("W\(index)\(sideLabel)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.orange)

                // Position label at the middle of the wall
                let labelY = (topY + bottomY) / 2
                let labelX = wall.side == .left ? x + 4 : x - 24
                context.draw(label, at: CGPoint(x: labelX, y: labelY))

                // Draw small tick marks at wall bounds
                let tickSize: CGFloat = 4
                let tickPath = Path { path in
                    // Top tick
                    path.move(to: CGPoint(x: x - tickSize, y: topY))
                    path.addLine(to: CGPoint(x: x + tickSize, y: topY))
                    // Bottom tick
                    path.move(to: CGPoint(x: x - tickSize, y: bottomY))
                    path.addLine(to: CGPoint(x: x + tickSize, y: bottomY))
                }
                context.stroke(tickPath, with: .color(.orange.opacity(0.6)), lineWidth: 1)
            }

            // Draw sprite bounding boxes
            for (index, sprite) in spriteBounds.enumerated() {
                // Convert from Cocoa coordinates to SwiftUI
                // Position is bottom-center of sprite, so rect goes from position.y to position.y + size.height
                let spriteTop = screenHeight - (sprite.position.y + sprite.size.height) - offsetY
                let spriteBottom = screenHeight - sprite.position.y - offsetY
                let spriteLeft = sprite.position.x - sprite.size.width / 2 - offsetX
                let spriteRight = sprite.position.x + sprite.size.width / 2 - offsetX

                let rect = CGRect(
                    x: spriteLeft,
                    y: spriteTop,
                    width: spriteRight - spriteLeft,
                    height: spriteBottom - spriteTop
                )

                // Skip if not visible on this screen
                if rect.maxX < 0 || rect.minX > size.width || rect.maxY < 0 || rect.minY > size.height {
                    continue
                }

                let spritePath = Path { path in
                    path.addRect(rect)
                }

                // Use red for sprite bounds to stand out
                context.stroke(spritePath, with: .color(.red.opacity(0.9)), lineWidth: 2)

                // Draw sprite info with status
                let statusText = sprite.status?.rawValue ?? "none"
                let spriteLabel = Text("S\(index) [\(statusText)]")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                context.draw(spriteLabel, at: CGPoint(x: spriteLeft + 4, y: spriteTop + 12))

                // Draw position crosshair at sprite's physics position
                let crosshairY = screenHeight - sprite.position.y - offsetY
                let crosshairX = sprite.position.x - offsetX
                let crosshairSize: CGFloat = 6

                let crosshairPath = Path { path in
                    path.move(to: CGPoint(x: crosshairX - crosshairSize, y: crosshairY))
                    path.addLine(to: CGPoint(x: crosshairX + crosshairSize, y: crosshairY))
                    path.move(to: CGPoint(x: crosshairX, y: crosshairY - crosshairSize))
                    path.addLine(to: CGPoint(x: crosshairX, y: crosshairY + crosshairSize))
                }
                context.stroke(crosshairPath, with: .color(.red), lineWidth: 1)
            }
        }
    }
}
