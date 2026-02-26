import AppKit
import SwiftUI
import AgentSpritesCore

/// Manages the retro terminal popup window for attention states
@MainActor
final class MessageWindowController {
    let sessionId: String
    private let panel: NSPanel
    private let hostingView: NSHostingView<MessageContentView>
    private var contentView: MessageContentView
    private var sessionName: String
    private var summary: String?

    var onFocusTerminal: (() -> Void)?
    var onDismiss: (() -> Void)?

    private static let windowSize = NSSize(width: 200, height: 100)

    init(sessionId: String, sessionName: String, summary: String?, message: String, status: SessionStatus, blobPosition: CGPoint) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.summary = summary

        let position = Self.calculatePosition(blobPosition: blobPosition)

        self.contentView = MessageContentView(
            sessionName: sessionName,
            summary: summary,
            message: message,
            status: status,
            onFocusTerminal: { },
            onDismiss: { }
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: position, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        self.panel = panel
        self.hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = panel.contentView?.bounds ?? .zero

        panel.contentView = hostingView

        // Wire up callbacks after initialization
        updateCallbacks()
    }

    private func updateCallbacks() {
        contentView = MessageContentView(
            sessionName: sessionName,
            summary: summary,
            message: contentView.message,
            status: contentView.status,
            onFocusTerminal: { [weak self] in
                self?.onFocusTerminal?()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?()
            }
        )
        hostingView.rootView = contentView
    }

    func show() {
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        panel.close()
    }

    func update(status: SessionStatus, summary: String? = nil) {
        if let summary {
            self.summary = summary
        }
        let message = messageFor(status: status)
        contentView = MessageContentView(
            sessionName: sessionName,
            summary: self.summary,
            message: message,
            status: status,
            onFocusTerminal: { [weak self] in
                self?.onFocusTerminal?()
            },
            onDismiss: { [weak self] in
                self?.onDismiss?()
            }
        )
        hostingView.rootView = contentView
    }

    func updatePosition(blobPosition: CGPoint) {
        let newPosition = Self.calculatePosition(blobPosition: blobPosition)
        panel.setFrameOrigin(newPosition)
    }

    private static func calculatePosition(blobPosition: CGPoint) -> CGPoint {
        // Position centered above the blob
        let blobSize: CGFloat = 64
        let gap: CGFloat = 8
        var position = CGPoint(
            x: blobPosition.x + blobSize / 2 - windowSize.width / 2,  // Centered horizontally
            y: blobPosition.y + blobSize + gap  // Above the blob
        )

        // Find the screen containing the blob
        let screen = NSScreen.screens.first { $0.frame.contains(blobPosition) } ?? NSScreen.main

        if let screen {
            let screenFrame = screen.visibleFrame

            // If doesn't fit above, position below the blob
            if position.y + windowSize.height > screenFrame.maxY - 5 {
                position.y = blobPosition.y - windowSize.height - gap
            }

            // Keep within horizontal bounds
            position.x = max(screenFrame.minX + 5, min(screenFrame.maxX - windowSize.width - 5, position.x))

            // Keep within vertical bounds
            position.y = max(screenFrame.minY + 5, min(screenFrame.maxY - windowSize.height - 5, position.y))
        }

        return position
    }

    private func messageFor(status: SessionStatus) -> String {
        switch status {
        case .waitingForInput:
            return "Waiting for your input..."
        case .waitingForPermission:
            return "Permission required"
        default:
            return "Attention needed"
        }
    }
}

/// SwiftUI wrapper for the message content
private struct MessageContentView: View {
    let sessionName: String
    let summary: String?
    let message: String
    let status: SessionStatus
    let onFocusTerminal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        RetroTerminalView(
            sessionName: sessionName,
            summary: summary,
            message: message,
            status: status,
            onFocusTerminal: onFocusTerminal,
            onDismiss: onDismiss
        )
    }
}
