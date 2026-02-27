import AppKit
import SwiftUI
import AgentSpritesCore

/// Observable model for sprite state - allows efficient SwiftUI updates
@MainActor
final class SpriteViewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var facingRight: Bool = true
    @Published var hueRotation: Double = 0
    @Published var surfaceRotation: Double = 0

    func update(image: NSImage?, facingRight: Bool, hueRotation: Double, surfaceRotation: Double) {
        // Only update properties that changed to minimize SwiftUI invalidation
        if self.image !== image {
            self.image = image
        }
        if self.facingRight != facingRight {
            self.facingRight = facingRight
        }
        if self.hueRotation != hueRotation {
            self.hueRotation = hueRotation
        }
        if self.surfaceRotation != surfaceRotation {
            self.surfaceRotation = surfaceRotation
        }
    }
}

/// Manages an NSPanel window for a single character sprite
@MainActor
final class SpriteWindowController {
    let sessionId: String
    private let panel: NSPanel
    private let viewModel: SpriteViewModel
    private let hostingView: NSHostingView<SpriteContentView>
    private var tooltipWindow: NSPanel?
    private var lastPosition: CGPoint = .zero

    private static let windowSize = CGSize(width: 64, height: 64)

    var onClick: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?  // Screen position
    var onDragEnd: (() -> Void)?
    var sessionInfo = SessionInfo()
    var hasMessageWindow: Bool = false  // Prevents tooltip when message is showing

    struct SessionInfo {
        var name: String = ""
        var status: String = ""
        var directory: String = ""
        var summary: String?
        var gitBranch: String?
    }

    init(sessionId: String) {
        self.sessionId = sessionId
        self.viewModel = SpriteViewModel()

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        panel.ignoresMouseEvents = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false

        self.panel = panel
        let contentView = SpriteContentView(viewModel: viewModel, size: Self.windowSize)
        self.hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = panel.contentView?.bounds ?? .zero

        panel.contentView = hostingView

        // Add click, hover, and drag handler
        let interactionView = InteractionView(frame: hostingView.bounds)
        interactionView.onClick = { [weak self] in
            self?.onClick?()
        }
        interactionView.onHoverEnter = { [weak self] in
            self?.showTooltip()
            self?.onHoverChanged?(true)
        }
        interactionView.onHoverExit = { [weak self] in
            self?.hideTooltip()
            self?.onHoverChanged?(false)
        }
        interactionView.onDragStart = { [weak self] in
            self?.hideTooltip()
            self?.onDragStart?()
        }
        interactionView.onDragUpdate = { [weak self] screenPoint in
            self?.onDragUpdate?(screenPoint)
        }
        interactionView.onDragEnd = { [weak self] in
            self?.onDragEnd?()
        }
        interactionView.autoresizingMask = [.width, .height]
        hostingView.addSubview(interactionView)
    }

    func show() {
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
        hideTooltip()
    }

    func close() {
        panel.close()
        hideTooltip()
    }

    func update(image: NSImage?, facingRight: Bool, screenPosition: CGPoint, hueRotation: Double, surfaceRotation: Double = 0) {
        // Update view model - only changed properties trigger SwiftUI updates
        viewModel.update(image: image, facingRight: facingRight, hueRotation: hueRotation, surfaceRotation: surfaceRotation)

        // Only update window position if it changed by at least 0.5 pixels (avoid expensive window operations for sub-pixel movement)
        let dx = abs(lastPosition.x - screenPosition.x)
        let dy = abs(lastPosition.y - screenPosition.y)
        if dx >= 0.5 || dy >= 0.5 {
            lastPosition = screenPosition
            let windowOrigin = CGPoint(
                x: screenPosition.x - Self.windowSize.width / 2,
                y: screenPosition.y
            )
            panel.setFrameOrigin(windowOrigin)

            // Update tooltip position if visible
            if let tooltip = tooltipWindow, tooltip.isVisible {
                positionTooltip()
            }
        }
    }

    private func showTooltip() {
        // Don't show tooltip when message window is visible
        guard !hasMessageWindow else { return }

        if tooltipWindow == nil {
            createTooltipWindow()
        }
        positionTooltip()
        tooltipWindow?.orderFront(nil)
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
    }

    private func createTooltipWindow() {
        let tooltip = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        tooltip.isOpaque = false
        tooltip.backgroundColor = .clear
        tooltip.hasShadow = false
        tooltip.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        tooltip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        tooltip.ignoresMouseEvents = true

        let tooltipView = TooltipView(info: sessionInfo)
        let hostingView = NSHostingView(rootView: tooltipView)
        tooltip.contentView = hostingView

        tooltipWindow = tooltip
    }

    private func positionTooltip() {
        guard let tooltip = tooltipWindow,
              let hostingView = tooltip.contentView as? NSHostingView<TooltipView> else { return }

        // Update content
        hostingView.rootView = TooltipView(info: sessionInfo)

        // Fit to content
        let fittingSize = hostingView.fittingSize
        tooltip.setContentSize(fittingSize)

        // Position centered above the sprite
        let spriteFrame = panel.frame
        let gap: CGFloat = 8
        var tooltipOrigin = CGPoint(
            x: spriteFrame.midX - fittingSize.width / 2,  // Centered horizontally
            y: spriteFrame.maxY + gap  // Above the sprite
        )

        // Find the screen containing the sprite (use center of sprite frame)
        let spriteCenter = CGPoint(x: spriteFrame.midX, y: spriteFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(spriteCenter) } ?? NSScreen.main

        // Keep on screen
        if let screen {
            let screenFrame = screen.visibleFrame

            // If doesn't fit above, position below the sprite
            if tooltipOrigin.y + fittingSize.height > screenFrame.maxY - 5 {
                tooltipOrigin.y = spriteFrame.minY - fittingSize.height - gap
            }

            // Keep within horizontal bounds
            tooltipOrigin.x = max(screenFrame.minX + 5, min(screenFrame.maxX - fittingSize.width - 5, tooltipOrigin.x))

            // Keep within vertical bounds
            tooltipOrigin.y = max(screenFrame.minY + 5, min(screenFrame.maxY - fittingSize.height - 5, tooltipOrigin.y))
        }

        tooltip.setFrameOrigin(tooltipOrigin)
    }
}

/// Tooltip view using terminal frame style
private struct TooltipView: View {
    let info: SpriteWindowController.SessionInfo

    var body: some View {
        TerminalFrame {
            VStack(alignment: .leading, spacing: 4) {
                // Show summary as title if available, otherwise folder name
                Text(info.summary ?? info.name)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SpriteColors.terminalGreen)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(info.status.uppercased())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(SpriteColors.terminalDimGreen)

                    // Show git branch if available
                    if let branch = info.gitBranch, !branch.isEmpty {
                        Text("•")
                            .font(.system(size: 9))
                            .foregroundColor(SpriteColors.terminalDimGreen.opacity(0.5))
                        Text(branch)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(SpriteColors.terminalDimGreen)
                    }
                }

                Text(info.directory)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(SpriteColors.terminalDimGreen.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
        }
        .frame(minWidth: 150, maxWidth: 220)
    }
}

/// SwiftUI wrapper view for the sprite - observes view model for efficient updates
private struct SpriteContentView: View {
    @ObservedObject var viewModel: SpriteViewModel
    let size: CGSize

    var body: some View {
        SpriteView(image: viewModel.image, facingRight: viewModel.facingRight, size: size, rotation: viewModel.surfaceRotation)
            .hueRotation(Angle(degrees: viewModel.hueRotation))
    }
}

/// NSView that handles click, hover, and drag events
private class InteractionView: NSView {
    var onClick: (() -> Void)?
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?
    var onDragStart: (() -> Void)?
    var onDragUpdate: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var isDragging = false
    private var mouseDownLocation: NSPoint?
    private static let dragThreshold: CGFloat = 3

    override init(frame: NSRect) {
        super.init(frame: frame)
        updateTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        updateTrackingArea()
    }

    private func updateTrackingArea() {
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation else { return }

        let currentLocation = event.locationInWindow
        let distance = hypot(currentLocation.x - startLocation.x, currentLocation.y - startLocation.y)

        if !isDragging && distance > Self.dragThreshold {
            isDragging = true
            onDragStart?()
        }

        if isDragging {
            // Use global mouse position (more reliable during drag)
            let screenPoint = NSEvent.mouseLocation
            onDragUpdate?(screenPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnd?()
        } else {
            onClick?()
        }
        isDragging = false
        mouseDownLocation = nil
    }

    override func mouseEntered(with event: NSEvent) {
        if !isDragging {
            onHoverEnter?()
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !isDragging {
            onHoverExit?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if bounds.contains(point) {
            return self
        }
        return nil
    }
}
