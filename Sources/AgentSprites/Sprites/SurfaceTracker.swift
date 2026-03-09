import Foundation

/// Tracks which surface a sprite is on and manages position/velocity manually.
/// Replaces SpriteKit physics with direct position control for predictable behavior.
struct SurfaceTracker {
    /// Current surface the sprite is resting on
    var currentSurface: SpriteSurface = .falling

    /// Per-sprite velocity in global coordinates
    var velocity: CGPoint = .zero

    /// Cached ledge bounds when on a ledge
    var currentLedgeY: CGFloat?
    var currentLedgeMinX: CGFloat?
    var currentLedgeMaxX: CGFloat?

    /// Cached wall bounds when on a window wall
    var currentWallX: CGFloat?
    var currentWallMinY: CGFloat?
    var currentWallMaxY: CGFloat?

    // MARK: - Gravity

    /// Gravity strength in points/s²
    private static let gravity: CGFloat = 400

    /// Maximum fall speed
    private static let terminalVelocity: CGFloat = 600

    /// Air friction multiplier (applied per second)
    private static let airDamping: CGFloat = 0.97

    // MARK: - Computed Properties

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

    // MARK: - Physics Update

    /// Apply gravity and move the sprite. Returns the new global position.
    mutating func update(position: CGPoint, dt: CGFloat) -> CGPoint {
        guard currentSurface == .falling else { return position }

        // Apply gravity
        velocity.y -= Self.gravity * dt

        // Clamp to terminal velocity
        velocity.y = max(velocity.y, -Self.terminalVelocity)

        // Apply air damping to horizontal velocity
        let dampingFactor = pow(Self.airDamping, dt * 60)
        velocity.x *= dampingFactor

        return CGPoint(
            x: position.x + velocity.x * dt,
            y: position.y + velocity.y * dt
        )
    }

    /// Check if the sprite has landed on any surface after falling.
    /// Returns the corrected position if landed, or nil if still falling.
    mutating func checkLanding(
        position: CGPoint,
        previousY: CGFloat,
        screenBounds: CGRect,
        ledges: [WindowObserver.Ledge]
    ) -> CGPoint? {
        guard currentSurface == .falling, velocity.y < 0 else { return nil }

        let floorY = screenBounds.minY

        // Check ledges first (higher surfaces take priority)
        // Only land if we crossed the ledge from above
        for ledge in ledges {
            guard ledge.contains(x: position.x) else { continue }
            if previousY >= ledge.y - 5 && position.y <= ledge.y + 5 {
                landOnLedge(ledge)
                return CGPoint(x: position.x, y: ledge.y)
            }
        }

        // Check floor
        if position.y <= floorY {
            landOnFloor(y: floorY, screenBounds: screenBounds)
            return CGPoint(x: position.x, y: floorY)
        }

        return nil
    }

    // MARK: - Surface Transitions

    mutating func startFalling() {
        currentSurface = .falling
        clearSurfaceCache()
    }

    mutating func landOnFloor(y: CGFloat, screenBounds: CGRect) {
        currentSurface = .floor
        currentLedgeY = y
        currentLedgeMinX = screenBounds.minX
        currentLedgeMaxX = screenBounds.maxX
        velocity = .zero
        clearWallCache()
    }

    mutating func landOnLedge(_ ledge: WindowObserver.Ledge) {
        currentSurface = .ledge
        currentLedgeY = ledge.y
        currentLedgeMinX = ledge.minX
        currentLedgeMaxX = ledge.maxX
        velocity = .zero
        clearWallCache()
    }

    mutating func startClimbingScreenWall(isLeftWall: Bool) {
        currentSurface = isLeftWall ? .leftWall : .rightWall
        velocity = .zero
        clearLedgeCache()
        clearWallCache()
    }

    mutating func startClimbingWindowWall(wall: WindowObserver.Wall) {
        currentSurface = .windowWall(x: wall.x, side: wall.side)
        velocity = .zero
        currentWallX = wall.x
        currentWallMinY = wall.minY
        currentWallMaxY = wall.maxY
        clearLedgeCache()
    }

    mutating func transitionToCeiling() {
        currentSurface = .ceiling
        velocity = .zero
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
