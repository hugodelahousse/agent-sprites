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
    private(set) var currentStatus: SessionStatus

    var onFocusTerminal: (() -> Void)?
    var onDismiss: (() -> Void)?
    private(set) var isVisible = false

    private static let windowSize = NSSize(width: 200, height: 100)

    init(sessionId: String, sessionName: String, summary: String?, message: String, status: SessionStatus, spritePosition: CGPoint) {
        self.sessionId = sessionId
        self.sessionName = sessionName
        self.summary = summary
        self.currentStatus = status

        let position = Self.calculatePosition(spritePosition: spritePosition)

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
        guard !isVisible else { return }
        isVisible = true
        if !panel.isVisible {
            panel.orderFront(nil)
        }
        panel.alphaValue = 1
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        panel.alphaValue = 0
    }

    func close() {
        isVisible = false
        panel.close()
    }

    func update(status: SessionStatus, summary: String? = nil) {
        let summaryChanged = summary != nil && summary != self.summary
        guard status != currentStatus || summaryChanged else { return }
        currentStatus = status
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

    func updatePosition(spritePosition: CGPoint) {
        let newPosition = Self.calculatePosition(spritePosition: spritePosition)
        panel.setFrameOrigin(newPosition)
    }

    private static func calculatePosition(spritePosition: CGPoint) -> CGPoint {
        // Position centered above the sprite
        let spriteSize: CGFloat = 64
        let gap: CGFloat = 8
        var position = CGPoint(
            x: spritePosition.x + spriteSize / 2 - windowSize.width / 2,  // Centered horizontally
            y: spritePosition.y + spriteSize + gap  // Above the sprite
        )

        // Find the screen containing the sprite
        let screen = NSScreen.screens.first { $0.frame.contains(spritePosition) } ?? NSScreen.main

        if let screen {
            let screenFrame = screen.visibleFrame

            // If doesn't fit above, position below the sprite
            if position.y + windowSize.height > screenFrame.maxY - 5 {
                position.y = spritePosition.y - windowSize.height - gap
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
