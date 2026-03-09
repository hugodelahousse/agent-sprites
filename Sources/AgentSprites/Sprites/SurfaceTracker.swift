import Foundation
import SpriteKit

/// Tracks which surface a sprite is on and manages gravity field switching
struct SurfaceTracker {
    /// Current surface the sprite is resting on
    var currentSurface: SpriteSurface = .falling

    /// Cached ledge bounds when on a ledge
    var currentLedgeY: CGFloat?
    var currentLedgeMinX: CGFloat?
    var currentLedgeMaxX: CGFloat?

    /// Cached wall bounds when on a window wall
    var currentWallX: CGFloat?
    var currentWallMinY: CGFloat?
    var currentWallMaxY: CGFloat?

    /// Grace period to avoid jitter when contact breaks momentarily
    private var lastContactTime: CFAbsoluteTime = 0
    private static let graceInterval: TimeInterval = 0.1

    /// Returns the gravity field bitmask for the current surface
    var fieldBitMask: UInt32 {
        switch currentSurface {
        case .floor, .ledge, .falling:
            return GravityCategory.down
        case .leftWall, .windowWall(_, .left):
            return GravityCategory.left
        case .rightWall, .windowWall(_, .right):
            return GravityCategory.right
        case .ceiling:
            return GravityCategory.up
        case .windowWall:
            // Default for ambiguous window wall
            return GravityCategory.down
        }
    }

    /// Returns the rotation angle for the sprite based on current surface
    var surfaceRotation: Double {
        switch currentSurface {
        case .leftWall:
            return -.pi / 2
        case .rightWall:
            return .pi / 2
        case .windowWall(_, let side):
            return side == .left ? -.pi / 2 : .pi / 2
        case .ceiling:
            return .pi
        default:
            return 0
        }
    }

    var isClimbing: Bool {
        switch currentSurface {
        case .leftWall, .rightWall, .windowWall:
            return true
        default:
            return false
        }
    }

    var isOnCeiling: Bool {
        currentSurface == .ceiling
    }

    /// Process a physics contact and update surface state.
    /// Only transitions surface when the sprite is falling — ignores contacts
    /// when already settled on a surface to prevent gravity oscillation.
    /// Also ignores glancing contacts where the sprite is moving too fast
    /// along the surface (brushing past a ledge edge during fall).
    mutating func handleContact(normal: CGVector, body: SKPhysicsBody) {
        lastContactTime = CFAbsoluteTimeGetCurrent()

        // Only process contacts when falling (transitioning between surfaces).
        // When already on a surface, the coordinator handles transitions explicitly.
        guard currentSurface == .falling else { return }

        let vel = body.velocity

        if normal.dy > 0.7 {
            // Skip if falling too fast — just brushing past a ledge edge
            guard vel.dy > -100 else { return }
            // Landed on a horizontal surface (floor/ledge) — gravity down
            currentSurface = .floor  // Coordinator refines to .ledge if applicable
            body.fieldBitMask = GravityCategory.down
            body.velocity = CGVector(dx: vel.dx, dy: 0)
        } else if normal.dx > 0.7 {
            guard vel.dx > -100 else { return }
            // Hit left wall — gravity pulls left
            currentSurface = .leftWall
            body.fieldBitMask = GravityCategory.left
        } else if normal.dx < -0.7 {
            guard vel.dx < 100 else { return }
            // Hit right wall — gravity pulls right
            currentSurface = .rightWall
            body.fieldBitMask = GravityCategory.right
        } else if normal.dy < -0.7 {
            guard vel.dy < 100 else { return }
            // Hit ceiling — gravity pulls up
            currentSurface = .ceiling
            body.fieldBitMask = GravityCategory.up
        }
    }

    /// Check if contact grace period has expired (sprite may have detached)
    var isInGracePeriod: Bool {
        CFAbsoluteTimeGetCurrent() - lastContactTime < Self.graceInterval
    }

    /// Transition to falling state
    mutating func startFalling(body: SKPhysicsBody) {
        currentSurface = .falling
        body.fieldBitMask = GravityCategory.down
        clearSurfaceCache()
    }

    /// Set surface to floor with bounds
    mutating func landOnFloor(y: CGFloat, screenBounds: CGRect, body: SKPhysicsBody) {
        currentSurface = .floor
        currentLedgeY = y
        currentLedgeMinX = screenBounds.minX
        currentLedgeMaxX = screenBounds.maxX
        body.fieldBitMask = GravityCategory.down
        clearWallCache()
    }

    /// Set surface to a specific ledge
    mutating func landOnLedge(_ ledge: WindowObserver.Ledge, body: SKPhysicsBody) {
        currentSurface = .ledge
        currentLedgeY = ledge.y
        currentLedgeMinX = ledge.minX
        currentLedgeMaxX = ledge.maxX
        body.fieldBitMask = GravityCategory.down
        clearWallCache()
    }

    /// Start climbing a screen wall
    mutating func startClimbingScreenWall(isLeftWall: Bool, body: SKPhysicsBody) {
        currentSurface = isLeftWall ? .leftWall : .rightWall
        body.fieldBitMask = isLeftWall ? GravityCategory.left : GravityCategory.right
        clearLedgeCache()
        clearWallCache()
    }

    /// Start climbing a window wall
    mutating func startClimbingWindowWall(wall: WindowObserver.Wall, body: SKPhysicsBody) {
        currentSurface = .windowWall(x: wall.x, side: wall.side)
        body.fieldBitMask = wall.side == .left ? GravityCategory.left : GravityCategory.right
        currentWallX = wall.x
        currentWallMinY = wall.minY
        currentWallMaxY = wall.maxY
        clearLedgeCache()
    }

    /// Transition to ceiling
    mutating func transitionToCeiling(body: SKPhysicsBody) {
        currentSurface = .ceiling
        body.fieldBitMask = GravityCategory.up
        clearLedgeCache()
        clearWallCache()
    }

    /// Clear all surface caches (for drag start, etc.)
    mutating func clearAllCaches() {
        clearLedgeCache()
        clearWallCache()
    }

    private mutating func clearLedgeCache() {
        currentLedgeY = nil
        currentLedgeMinX = nil
        currentLedgeMaxX = nil
    }

    private mutating func clearWallCache() {
        currentWallX = nil
        currentWallMinY = nil
        currentWallMaxY = nil
    }

    private mutating func clearSurfaceCache() {
        clearLedgeCache()
        clearWallCache()
    }
}
