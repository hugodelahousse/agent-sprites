import AppKit
import SpriteKit
import os

/// Custom SKView that passes clicks through empty areas
/// Only captures clicks on sprite nodes via scene hit testing
private class TransparentSKView: SKView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let scene = scene as? SpriteScene else { return nil }

        let scenePoint = convert(point, to: scene)
        let hitNodes = scene.nodes(at: scenePoint)
        let hitSprite = hitNodes.contains { $0.name?.hasPrefix("sprite_") == true }

        return hitSprite ? self : nil
    }

    override func mouseMoved(with event: NSEvent) {
        scene?.mouseMoved(with: event)
    }
}

/// Manages a fullscreen transparent window + SKView for one screen
/// Replaces per-sprite SpriteWindowController with a single scene per display
@MainActor
final class SpriteSceneController {
    let displayID: CGDirectDisplayID
    let panel: NSPanel
    private let skView: TransparentSKView
    let scene: SpriteScene

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SpriteSceneController")

    init(screen: NSScreen) {
        self.displayID = screen.displayID

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .stationary]
        panel.ignoresMouseEvents = true  // Start ignoring — updated each frame
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true

        self.panel = panel

        let skView = TransparentSKView(frame: NSRect(origin: .zero, size: screen.frame.size))
        skView.allowsTransparency = true
        skView.autoresizingMask = [.width, .height]

        // Tracking area for mouse moved events
        let trackingArea = NSTrackingArea(
            rect: skView.bounds,
            options: [.mouseMoved, .activeAlways, .inVisibleRect],
            owner: skView,
            userInfo: nil
        )
        skView.addTrackingArea(trackingArea)

        self.skView = skView
        panel.contentView = skView

        let scene = SpriteScene(size: screen.frame.size)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        self.scene = scene

        skView.presentScene(scene)

        // Start paused (no sprites yet)
        skView.isPaused = true

        logger.debug("Created SpriteSceneController for display \(self.displayID, privacy: .public) size=\(screen.frame.size.width, privacy: .public)x\(screen.frame.size.height, privacy: .public)")
    }

    func show() {
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func close() {
        skView.isPaused = true
        panel.close()
    }

    /// Update pause and visibility based on sprite count
    func updatePauseState() {
        let hasSprites = scene.spriteCount > 0
        setPaused(!hasSprites)
        if hasSprites && !panel.isVisible {
            panel.orderFront(nil)
        } else if !hasSprites && panel.isVisible {
            panel.orderOut(nil)
        }
    }

    /// Explicitly set paused state
    func setPaused(_ paused: Bool) {
        if skView.isPaused != paused {
            skView.isPaused = paused
            logger.debug("Display \(self.displayID, privacy: .public) paused=\(paused, privacy: .public)")
        }
    }

    /// Throttle frame rate: full speed when sprites are active, low FPS when idle
    func setNeedsFullFrameRate(_ needsFullRate: Bool) {
        let target = needsFullRate ? 60 : 4
        if skView.preferredFramesPerSecond != target {
            skView.preferredFramesPerSecond = target
        }
    }

    /// Update the panel frame to match current screen bounds
    func updateFrame(for screen: NSScreen) {
        panel.setFrame(screen.frame, display: true)
        scene.size = screen.frame.size
    }

    /// Called each animation frame to toggle ignoresMouseEvents based on mouse position.
    /// Returns the session ID of the sprite under the mouse, or nil if none.
    @discardableResult
    func updateMousePassthrough() -> String? {
        let mouseLocation = NSEvent.mouseLocation

        // Quick bounds check — skip hit test if mouse isn't even in this panel's frame
        guard panel.frame.contains(mouseLocation) else {
            if !panel.ignoresMouseEvents {
                panel.ignoresMouseEvents = true
            }
            return nil
        }

        let windowPoint = panel.convertPoint(fromScreen: mouseLocation)
        let viewPoint = skView.convert(windowPoint, from: nil)
        let scenePoint = skView.convert(viewPoint, to: scene)
        let hitNodes = scene.nodes(at: scenePoint)

        let spritePrefix = "sprite_"
        let hitSpriteNode = hitNodes.first { $0.name?.hasPrefix(spritePrefix) == true }
        let overSprite = hitSpriteNode != nil

        if panel.ignoresMouseEvents == overSprite {
            panel.ignoresMouseEvents = !overSprite
        }

        if let name = hitSpriteNode?.name {
            return String(name.dropFirst(spritePrefix.count))
        }
        return nil
    }
}

// MARK: - NSScreen Display ID Helper

extension NSScreen {
    /// Get the CGDirectDisplayID for this screen
    var displayID: CGDirectDisplayID {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else {
            return CGMainDisplayID()
        }
        return CGDirectDisplayID(screenNumber)
    }
}
