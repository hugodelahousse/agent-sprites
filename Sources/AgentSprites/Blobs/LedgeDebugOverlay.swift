import AppKit
import SwiftUI

/// Represents a blob's bounding box for debug visualization
struct BlobBounds {
    let sessionId: String
    let position: CGPoint  // Bottom-center of blob (Cocoa coords)
    let size: CGSize       // 64x64 typically
}

/// Debug overlay that shows ledge positions as lines on all screens
@MainActor
final class LedgeDebugOverlay {
    private var windows: [NSWindow] = []
    private var isVisible = false
    private let windowObserver = WindowObserver.shared

    /// Callback to get current blob bounds from coordinator
    var getBlobBounds: (() -> [BlobBounds])?

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
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self, self.isVisible else {
                    timer.invalidate()
                    return
                }
                self.updateLedges()
            }
        }
    }

    private func updateLedges() {
        let screens = NSScreen.screens
        let ledges = windowObserver.getLedges()
        let windowFrames = windowObserver.getWindowFrames()
        let blobBounds = getBlobBounds?() ?? []

        // Use primary screen height for coordinate conversion (matches CGWindow coords)
        let primaryScreenHeight = screens.first?.frame.height ?? 0

        for (index, screen) in screens.enumerated() {
            guard index < windows.count else { continue }
            let window = windows[index]

            let groundY = screen.visibleFrame.minY

            let view = LedgeDebugView(
                ledges: ledges,
                windowFrames: windowFrames,
                blobBounds: blobBounds,
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

/// SwiftUI view that draws ledge lines and window frames
private struct LedgeDebugView: View {
    let ledges: [WindowObserver.Ledge]
    let windowFrames: [WindowObserver.WindowFrame]
    let blobBounds: [BlobBounds]
    let groundY: CGFloat
    let screenHeight: CGFloat  // Primary screen height for coordinate conversion
    let screenBounds: CGRect   // This screen's visible frame
    let screenFrame: CGRect    // This screen's full frame

    var body: some View {
        Canvas { context, size in
            // Offset for translating global coordinates to this screen's local coordinates
            let offsetX = screenFrame.minX
            let offsetY = screenFrame.minY

            // Draw canvas bounds (screen.visibleFrame - where blobs can exist)
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
            let canvasLabel = Text("BLOB CANVAS").font(.system(size: 10, weight: .bold, design: .monospaced))
            context.draw(canvasLabel, at: CGPoint(x: canvasLeft + 5, y: canvasTop + 14))

            // Draw window frames (so ledges appear on top)
            for (index, frame) in windowFrames.enumerated() {
                // Convert from Cocoa coordinates to SwiftUI (relative to this screen)
                let top = screenHeight - frame.maxY - offsetY
                let bottom = screenHeight - frame.minY - offsetY
                let left = frame.minX - offsetX
                let rect = CGRect(x: left, y: top, width: frame.maxX - frame.minX, height: bottom - top)

                // Skip if not visible on this screen
                if rect.maxX < 0 || rect.minX > size.width || rect.maxY < 0 || rect.minY > size.height {
                    continue
                }

                let framePath = Path { path in
                    path.addRect(rect)
                }

                // Use different colors for each window
                let colors: [Color] = [.orange, .purple, .yellow, .teal]
                let color = colors[index % colors.count]
                context.stroke(framePath, with: .color(color.opacity(0.5)), lineWidth: 1)

                // Draw window name
                let nameText = Text(frame.name)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(color)
                context.draw(nameText, at: CGPoint(x: left + 4, y: top + 12))
            }

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

            // Draw ledge lines
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

            // Draw blob bounding boxes
            for (index, blob) in blobBounds.enumerated() {
                // Convert from Cocoa coordinates to SwiftUI
                // Position is bottom-center of blob, so rect goes from position.y to position.y + size.height
                let blobTop = screenHeight - (blob.position.y + blob.size.height) - offsetY
                let blobBottom = screenHeight - blob.position.y - offsetY
                let blobLeft = blob.position.x - blob.size.width / 2 - offsetX
                let blobRight = blob.position.x + blob.size.width / 2 - offsetX

                let rect = CGRect(
                    x: blobLeft,
                    y: blobTop,
                    width: blobRight - blobLeft,
                    height: blobBottom - blobTop
                )

                // Skip if not visible on this screen
                if rect.maxX < 0 || rect.minX > size.width || rect.maxY < 0 || rect.minY > size.height {
                    continue
                }

                let blobPath = Path { path in
                    path.addRect(rect)
                }

                // Use red for blob bounds to stand out
                context.stroke(blobPath, with: .color(.red.opacity(0.9)), lineWidth: 2)

                // Draw blob info
                let blobLabel = Text("B\(index)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                context.draw(blobLabel, at: CGPoint(x: blobLeft + 4, y: blobTop + 12))

                // Draw position crosshair at blob's physics position
                let crosshairY = screenHeight - blob.position.y - offsetY
                let crosshairX = blob.position.x - offsetX
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
