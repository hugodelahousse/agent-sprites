import AppKit
import SpriteKit
import os

/// SKScene subclass that manages sprite nodes keyed by session ID
/// Handles mouse events with hit testing and forwards to coordinator via callbacks
/// Owns the SpriteKit physics world with gravity fields and surface edge bodies
class SpriteScene: SKScene, SKPhysicsContactDelegate {
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SpriteScene")

    /// Sprite nodes keyed by session ID
    private var spriteNodes: [String: SKSpriteNode] = [:]

    /// Node name prefix for sprite identification
    private static let spriteNodePrefix = "sprite_"

    // MARK: - Physics

    /// Gravity field strength — low for a floaty, gentle fall
    private static let gravityStrength: Float = 20

    /// Gravity field nodes
    private var gravityDown: SKFieldNode?
    private var gravityLeft: SKFieldNode?
    private var gravityUp: SKFieldNode?
    private var gravityRight: SKFieldNode?

    /// Permanent screen boundaries (floor, ceiling, screen walls) — created once per screen
    private var boundaryNode: SKNode?

    /// Dynamic window surfaces (ledges, window walls) — rebuilt when layout changes
    private var dynamicSurfacesNode: SKNode?

    /// Callback when a contact begins (sessionId, contact normal)
    var onContactBegan: ((String, CGVector) -> Void)?

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

        // Zero world gravity — we use per-sprite field nodes instead
        physicsWorld.gravity = .zero
        physicsWorld.contactDelegate = self

        setupGravityFields()
    }

    private func setupGravityFields() {
        // Down (default for floor/ledge/falling sprites)
        let down = SKFieldNode.linearGravityField(withVector: vector_float3(0, -1, 0))
        down.strength = Self.gravityStrength
        down.categoryBitMask = GravityCategory.down
        down.isExclusive = false
        addChild(down)
        gravityDown = down

        // Left (for sprites climbing left wall)
        let left = SKFieldNode.linearGravityField(withVector: vector_float3(-1, 0, 0))
        left.strength = Self.gravityStrength
        left.categoryBitMask = GravityCategory.left
        left.isExclusive = false
        addChild(left)
        gravityLeft = left

        // Up (for ceiling sprites)
        let up = SKFieldNode.linearGravityField(withVector: vector_float3(0, 1, 0))
        up.strength = Self.gravityStrength
        up.categoryBitMask = GravityCategory.up
        up.isExclusive = false
        addChild(up)
        gravityUp = up

        // Right (for sprites climbing right wall)
        let right = SKFieldNode.linearGravityField(withVector: vector_float3(1, 0, 0))
        right.strength = Self.gravityStrength
        right.categoryBitMask = GravityCategory.right
        right.isExclusive = false
        addChild(right)
        gravityRight = right
    }

    // MARK: - Surface Bodies

    /// Create permanent screen boundary edges (floor, ceiling, screen walls).
    /// Called once per screen; never removed during gameplay.
    ///
    /// - Parameters:
    ///   - visibleFrame: The screen's visibleFrame in global Cocoa coordinates
    ///   - screenFrame: The screen's full frame in global Cocoa coordinates
    func setupBoundaries(visibleFrame: CGRect, screenFrame: CGRect) {
        boundaryNode?.removeFromParent()

        let container = SKNode()
        container.name = "boundaries"

        // Scene coords: (0,0) = screenFrame.origin, size = screenFrame.size
        let origin = screenFrame.origin
        let sceneWidth = screenFrame.width

        // Floor: bottom of visible area (above dock/menu bar)
        let floorY = visibleFrame.minY - origin.y
        addSurfaceEdge(to: container, from: CGPoint(x: 0, y: floorY), to: CGPoint(x: sceneWidth, y: floorY))

        // Ceiling: top of visible area minus margin
        let ceilingY = (visibleFrame.maxY - origin.y) - 50
        addSurfaceEdge(to: container, from: CGPoint(x: 0, y: ceilingY), to: CGPoint(x: sceneWidth, y: ceilingY))

        // Screen walls: full height between floor and ceiling
        addSurfaceEdge(to: container, from: CGPoint(x: 0, y: floorY), to: CGPoint(x: 0, y: ceilingY))
        addSurfaceEdge(to: container, from: CGPoint(x: sceneWidth, y: floorY), to: CGPoint(x: sceneWidth, y: ceilingY))

        addChild(container)
        boundaryNode = container
    }

    /// Remove dynamic surfaces without replacing them.
    /// Called before setting sprites to falling so they don't immediately re-collide with old edges.
    func removeDynamicSurfaces() {
        dynamicSurfacesNode?.removeFromParent()
        dynamicSurfacesNode = nil
    }

    /// Rebuild dynamic window surface edge bodies (ledges, window walls).
    /// Called by coordinator when window layout changes. Permanent boundaries are untouched.
    func rebuildDynamicSurfaces(
        ledges: [WindowObserver.Ledge],
        walls: [WindowObserver.Wall],
        screenOrigin: CGPoint
    ) {
        dynamicSurfacesNode?.removeFromParent()

        let container = SKNode()
        container.name = "dynamicSurfaces"

        for ledge in ledges {
            let localMinX = ledge.minX - screenOrigin.x
            let localMaxX = ledge.maxX - screenOrigin.x
            let localY = ledge.y - screenOrigin.y
            addSurfaceEdge(to: container, from: CGPoint(x: localMinX, y: localY), to: CGPoint(x: localMaxX, y: localY))
        }

        for wall in walls {
            let localX = wall.x - screenOrigin.x
            let localMinY = wall.minY - screenOrigin.y
            let localMaxY = wall.maxY - screenOrigin.y
            addSurfaceEdge(to: container, from: CGPoint(x: localX, y: localMinY), to: CGPoint(x: localX, y: localMaxY))
        }

        addChild(container)
        dynamicSurfacesNode = container
    }

    private func addSurfaceEdge(to parent: SKNode, from start: CGPoint, to end: CGPoint) {
        let edge = SKNode()
        let body = SKPhysicsBody(edgeFrom: start, to: end)
        body.categoryBitMask = PhysicsCategory.surface
        body.collisionBitMask = PhysicsCategory.sprite
        body.contactTestBitMask = PhysicsCategory.sprite
        body.friction = 1.0
        body.restitution = 0
        edge.physicsBody = body
        parent.addChild(edge)
    }

    // MARK: - Physics Body Setup

    /// Add a physics body to a sprite node for physics simulation
    func addSpritePhysicsBody(sessionId: String) {
        guard let node = spriteNodes[sessionId] else { return }

        // Small rectangle at the feet only — prevents getting stuck on ledge edges.
        // Anchor is (0.5, 0) = bottom-center, so y=2 centers the 4pt-tall box just above the anchor.
        let body = SKPhysicsBody(rectangleOf: CGSize(width: 20, height: 4), center: CGPoint(x: 0, y: 2))
        body.categoryBitMask = PhysicsCategory.sprite
        body.collisionBitMask = PhysicsCategory.surface
        body.contactTestBitMask = PhysicsCategory.surface
        body.fieldBitMask = GravityCategory.down
        body.allowsRotation = false
        body.restitution = 0
        body.friction = 1.0
        body.linearDamping = 1.0
        body.mass = 1.0
        node.physicsBody = body
    }

    /// Get the physics body for a sprite
    func spriteBody(sessionId: String) -> SKPhysicsBody? {
        spriteNodes[sessionId]?.physicsBody
    }

    /// Get the sprite node for a session
    func spriteNode(sessionId: String) -> SKSpriteNode? {
        spriteNodes[sessionId]
    }

    // MARK: - Contact Delegate

    func didBegin(_ contact: SKPhysicsContact) {
        guard let result = extractSpriteContact(contact),
              let spriteNode = result.body.node as? SKSpriteNode,
              let name = spriteNode.name,
              name.hasPrefix(Self.spriteNodePrefix) else { return }

        let sessionId = String(name.dropFirst(Self.spriteNodePrefix.count))
        onContactBegan?(sessionId, result.normal)
    }

    /// Identify the sprite body and contact normal pointing away from the surface (toward sprite).
    /// SKPhysicsContact.contactNormal points from bodyA to bodyB.
    private func extractSpriteContact(_ contact: SKPhysicsContact) -> (body: SKPhysicsBody, normal: CGVector)? {
        let a = contact.bodyA
        let b = contact.bodyB

        if a.categoryBitMask == PhysicsCategory.sprite && b.categoryBitMask == PhysicsCategory.surface {
            // Normal points A→B = sprite→surface. Flip to get surface→sprite.
            let flipped = CGVector(dx: -contact.contactNormal.dx, dy: -contact.contactNormal.dy)
            return (a, flipped)
        } else if b.categoryBitMask == PhysicsCategory.sprite && a.categoryBitMask == PhysicsCategory.surface {
            // Normal points A→B = surface→sprite. Already correct direction.
            return (b, contact.contactNormal)
        }
        return nil
    }

    // MARK: - Game Loop

    /// Last frame time for clamping physics step size
    private var lastFrameTime: TimeInterval = 0

    /// Maximum physics step — prevents teleporting on frame rate transitions or hitches
    private static let maxPhysicsStep: TimeInterval = 1.0 / 10.0

    override func update(_ currentTime: TimeInterval) {
        super.update(currentTime)

        // Clamp physics step by adjusting physicsWorld.speed.
        // SpriteKit uses actual frame delta as its physics step, which causes
        // teleporting when switching from 4fps→60fps or during hitches.
        if lastFrameTime > 0 {
            let dt = currentTime - lastFrameTime
            if dt > Self.maxPhysicsStep {
                // Scale down physics so effective step = maxPhysicsStep
                physicsWorld.speed = CGFloat(Self.maxPhysicsStep / dt)
            } else {
                physicsWorld.speed = 1.0
            }
        }
        lastFrameTime = currentTime

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

    /// Update a sprite's visual state (texture, facing, rotation, shader — NOT position, which SK physics owns)
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
