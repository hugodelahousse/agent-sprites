import AppKit
import SwiftUI

/// Debug overlay that shows ledge positions as lines
@MainActor
final class LedgeDebugOverlay {
    private var window: NSWindow?
    private var isVisible = false
    private let windowObserver = WindowObserver.shared

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard let screen = NSScreen.main else { return }

        if window == nil {
            createWindow(screen: screen)
        }

        window?.setFrame(screen.frame, display: true)
        window?.orderFront(nil)
        isVisible = true

        // Start update timer
        startUpdating()
    }

    func hide() {
        window?.orderOut(nil)
        isVisible = false
    }

    private func createWindow(screen: NSScreen) {
        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        window.ignoresMouseEvents = true
        window.hasShadow = false

        self.window = window
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
        guard let window = window, let screen = NSScreen.main else { return }

        let ledges = windowObserver.getLedges()
        let groundY = screen.visibleFrame.minY

        let view = LedgeDebugView(ledges: ledges, groundY: groundY, screenHeight: screen.frame.height)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = window.contentView?.bounds ?? screen.frame

        window.contentView = hostingView
    }
}

/// SwiftUI view that draws ledge lines
private struct LedgeDebugView: View {
    let ledges: [WindowObserver.Ledge]
    let groundY: CGFloat
    let screenHeight: CGFloat

    var body: some View {
        Canvas { context, size in
            // Draw ground line
            let groundPath = Path { path in
                path.move(to: CGPoint(x: 0, y: size.height - groundY))
                path.addLine(to: CGPoint(x: size.width, y: size.height - groundY))
            }
            context.stroke(groundPath, with: .color(.green.opacity(0.8)), lineWidth: 2)

            // Draw ground label
            let groundText = Text("GROUND").font(.system(size: 10, weight: .bold, design: .monospaced))
            context.draw(groundText, at: CGPoint(x: 50, y: size.height - groundY - 12))

            // Draw ledge lines
            for (index, ledge) in ledges.enumerated() {
                // Convert from Cocoa coordinates (origin bottom-left) to SwiftUI (origin top-left)
                let y = size.height - ledge.y

                let ledgePath = Path { path in
                    path.move(to: CGPoint(x: ledge.minX, y: y))
                    path.addLine(to: CGPoint(x: ledge.maxX, y: y))
                }

                // Alternate colors for visibility
                let color: Color = index % 2 == 0 ? .cyan : .pink
                context.stroke(ledgePath, with: .color(color.opacity(0.8)), lineWidth: 2)

                // Draw ledge info
                let label = Text("L\(index) y=\(Int(ledge.y))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color)
                context.draw(label, at: CGPoint(x: ledge.minX + 5, y: y - 12))
            }
        }
    }
}
