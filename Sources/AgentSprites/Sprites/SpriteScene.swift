import AppKit
import SpriteKit
import os

/// SKScene subclass that manages sprite nodes keyed by session ID.
/// Handles mouse events with hit testing and forwards to coordinator via callbacks.
/// Position is controlled externally — no SpriteKit physics.
class SpriteScene: SKScene {
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SpriteScene")

    /// Sprite nodes keyed by session ID
    private(set) var spriteNodes: [String: SKSpriteNode] = [:]

    /// Node name prefix for sprite identification
    private static let spriteNodePrefix = "sprite_"

    // MARK: - Callbacks

    /// Called each frame by SpriteKit's render loop with the current time
    var onFrameUpdate: ((CFTimeInterval) -> Void)?

    var onSpriteClick: ((String) -> Void)?
    var onSpriteHoverEnter: ((String) -> Void)?
    var onSpriteHoverExit: ((String) -> Void)?
    var onSpriteDragStart: ((String) -> Void)?
    var onSpriteDragUpdate: ((String, CGPoint) -> Void)?  // Session ID, screen position
    var onSpriteDragEnd: ((String) -> Void)?

    // MARK: - Drag State

    private var dragSessionId: String?
    private var mouseDownLocation: CGPoint?
    private var mouseDownSessionId: String?
    private static let dragThreshold: CGFloat = 3

    /// Currently hovered sprite session ID
    private var hoveredSessionId: String?

    // MARK: - Setup

    override func didMove(to view: SKView) {
        super.didMove(to: view)
        backgroundColor = .clear
        scaleMode = .resizeFill
    }

    // MARK: - Game Loop

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)
        onFrameUpdate?(currentTime)
    }

    // MARK: - Sprite Management

    /// Maximum bounding box for sprite display
    private static let maxSpriteSize: CGFloat = 64

    func addSprite(sessionId: String, texture: SKTexture, size: CGSize) {
        guard spriteNodes[sessionId] == nil else { return }

        let displaySize = Self.aspectFitSize(for: texture, within: size)
        let node = SKSpriteNode(texture: texture, size: displaySize)
        node.name = Self.spriteNodePrefix + sessionId
        node.anchorPoint = CGPoint(x: 0.5, y: 0)  // Bottom-center anchor
        addChild(node)
        spriteNodes[sessionId] = node
    }

    func removeSprite(sessionId: String) -> Bool {
        guard let node = spriteNodes.removeValue(forKey: sessionId) else { return false }
        node.removeFromParent()
        if hoveredSessionId == sessionId {
            hoveredSessionId = nil
        }
        return true
    }

    func hasSprite(sessionId: String) -> Bool {
        spriteNodes[sessionId] != nil
    }

    /// Get the sprite node for a session
    func spriteNode(sessionId: String) -> SKSpriteNode? {
        spriteNodes[sessionId]
    }

    /// Update a sprite's visual state (texture, facing, rotation, shader)
    func updateSpriteVisuals(
        sessionId: String,
        texture: SKTexture,
        facingRight: Bool,
        surfaceRotation: Double,
        shader: SKShader?
    ) {
        guard let node = spriteNodes[sessionId] else { return }

        // Update texture and recalculate aspect-correct size when it changes
        if node.texture !== texture {
            node.texture = texture
            let displaySize = Self.aspectFitSize(for: texture, within: CGSize(width: Self.maxSpriteSize, height: Self.maxSpriteSize))
            if node.size != displaySize {
                node.size = displaySize
            }
        }

        // Facing: flip via xScale
        let xScale: CGFloat = facingRight ? 1 : -1
        if node.xScale != xScale {
            node.xScale = xScale
        }

        // Surface rotation
        let zRotation = CGFloat(surfaceRotation)
        if node.zRotation != zRotation {
            node.zRotation = zRotation
        }

        // Shader (hue rotation)
        if node.shader !== shader {
            node.shader = shader
        }
    }

    var spriteCount: Int {
        spriteNodes.count
    }

    /// Calculate display size that fits within bounds while preserving texture aspect ratio
    private static func aspectFitSize(for texture: SKTexture, within bounds: CGSize) -> CGSize {
        let texSize = texture.size()
        guard texSize.width > 0, texSize.height > 0 else { return bounds }

        let scale = min(bounds.width / texSize.width, bounds.height / texSize.height)
        return CGSize(width: texSize.width * scale, height: texSize.height * scale)
    }

    // MARK: - Hit Testing

    /// Find the session ID of a sprite at the given scene point
    private func sessionId(at scenePoint: CGPoint) -> String? {
        let hitNodes = nodes(at: scenePoint)
        for node in hitNodes {
            if let name = node.name, name.hasPrefix(Self.spriteNodePrefix) {
                return String(name.dropFirst(Self.spriteNodePrefix.count))
            }
        }
        return nil
    }

    // MARK: - Mouse Events

    override func mouseDown(with event: NSEvent) {
        let location = event.location(in: self)
        mouseDownLocation = location
        mouseDownSessionId = sessionId(at: location)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startLocation = mouseDownLocation,
              let sessionId = mouseDownSessionId ?? dragSessionId else { return }

        let location = event.location(in: self)

        if dragSessionId == nil {
            let distance = hypot(location.x - startLocation.x, location.y - startLocation.y)
            if distance > Self.dragThreshold {
                dragSessionId = sessionId
                // Hide hover on drag start
                if let hovered = hoveredSessionId {
                    hoveredSessionId = nil
                    onSpriteHoverExit?(hovered)
                }
                onSpriteDragStart?(sessionId)
            }
        }

        if dragSessionId != nil {
            // Convert to global screen coordinates
            let screenPoint = NSEvent.mouseLocation
            onSpriteDragUpdate?(sessionId, screenPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if let dragId = dragSessionId {
            onSpriteDragEnd?(dragId)
            dragSessionId = nil
        } else if let sessionId = mouseDownSessionId {
            onSpriteClick?(sessionId)
        }

        mouseDownLocation = nil
        mouseDownSessionId = nil
    }

    override func mouseMoved(with event: NSEvent) {
        let location = event.location(in: self)
        let hitId = sessionId(at: location)

        if hitId != hoveredSessionId {
            if let oldId = hoveredSessionId {
                onSpriteHoverExit?(oldId)
            }
            hoveredSessionId = hitId
            if let newId = hitId {
                onSpriteHoverEnter?(newId)
            }
        }
    }
}
