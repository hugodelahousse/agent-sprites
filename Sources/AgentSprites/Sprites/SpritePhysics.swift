import Foundation
import CoreGraphics

/// Surface type the sprite is currently on
enum SpriteSurface: Sendable, Equatable {
    case floor           // Walking on ground (screen bottom)
    case ledge           // Walking on window top
    case leftWall        // Climbing left screen edge
    case rightWall       // Climbing right screen edge
    case windowWall(x: CGFloat, side: WindowObserver.Wall.Side)  // Climbing window edge
    case ceiling         // Walking upside-down on screen top
    case falling         // Not on any surface
}

/// Physics simulation for sprites with gravity and ledge support
struct SpritePhysics: Sendable {
    var position: CGPoint
    var velocity: CGPoint = .zero
    var groundY: CGFloat

    // Surface tracking
    var currentSurface: SpriteSurface = .falling
    var currentLedgeY: CGFloat?
    var currentLedgeMinX: CGFloat?
    var currentLedgeMaxX: CGFloat?

    // Window wall tracking
    var currentWallX: CGFloat?
    var currentWallMinY: CGFloat?
    var currentWallMaxY: CGFloat?

    // Drag state
    var isDragging: Bool = false
    private var dragVelocityHistory: [CGPoint] = []
    private static let velocityHistoryCount = 5

    // Wander behavior
    private var targetPosition: CGFloat
    private var lastTargetChange = Date()

    // Physics constants
    private static let gravity: CGFloat = -800
    private static let moveSpeed: CGFloat = 35
    private static let climbSpeed: CGFloat = 30
    private static let maxFallSpeed: CGFloat = -600
    private static let maxThrowSpeed: CGFloat = 400
    private static let wanderInterval: TimeInterval = 4.0
    private static let edgeMargin: CGFloat = 32  // Distance from screen edge to trigger wall climb

    init(x: CGFloat, groundY: CGFloat) {
        self.position = CGPoint(x: x, y: groundY)
        self.groundY = groundY
        self.targetPosition = x
    }

    var isMoving: Bool {
        switch currentSurface {
        case .leftWall, .rightWall:
            return abs(velocity.y) > 2
        default:
            return abs(velocity.x) > 2
        }
    }

    var isFalling: Bool {
        currentSurface == .falling && velocity.y < -10
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

    var horizontalVelocity: CGFloat {
        velocity.x
    }

    /// Returns the rotation angle for the sprite based on current surface
    var surfaceRotation: Double {
        switch currentSurface {
        case .leftWall:
            return .pi / 2  // 90 degrees - facing right while climbing
        case .rightWall:
            return -.pi / 2  // -90 degrees - facing left while climbing
        case .windowWall(_, let side):
            // Window walls: left side = facing right, right side = facing left
            return side == .left ? .pi / 2 : -.pi / 2
        case .ceiling:
            return .pi  // 180 degrees - upside down
        default:
            return 0
        }
    }

    // MARK: - Drag Handling

    mutating func startDrag() {
        isDragging = true
        velocity = .zero
        dragVelocityHistory.removeAll()
        currentSurface = .falling
        currentLedgeY = nil
        currentLedgeMinX = nil
        currentLedgeMaxX = nil
        currentWallX = nil
        currentWallMinY = nil
        currentWallMaxY = nil
    }

    mutating func updateDrag(to newPosition: CGPoint, deltaTime: CGFloat) {
        guard isDragging, deltaTime > 0 else {
            position = newPosition
            return
        }

        // Calculate velocity from movement
        let dragVelocity = CGPoint(
            x: (newPosition.x - position.x) / deltaTime,
            y: (newPosition.y - position.y) / deltaTime
        )

        // Store in history for smoothing
        dragVelocityHistory.append(dragVelocity)
        if dragVelocityHistory.count > Self.velocityHistoryCount {
            dragVelocityHistory.removeFirst()
        }

        position = newPosition
    }

    mutating func endDrag() {
        isDragging = false
        currentSurface = .falling  // Always start falling after drag

        // Use average velocity from history
        if !dragVelocityHistory.isEmpty {
            let avgVelocity = dragVelocityHistory.reduce(CGPoint.zero) { result, v in
                CGPoint(x: result.x + v.x, y: result.y + v.y)
            }
            let count = CGFloat(dragVelocityHistory.count)
            var throwVelocity = CGPoint(
                x: avgVelocity.x / count,
                y: avgVelocity.y / count
            )

            // Clamp to max throw speed
            throwVelocity.x = max(-Self.maxThrowSpeed, min(Self.maxThrowSpeed, throwVelocity.x))
            throwVelocity.y = max(-Self.maxThrowSpeed, min(Self.maxThrowSpeed, throwVelocity.y))
            velocity = throwVelocity
        }

        dragVelocityHistory.removeAll()
    }

    // MARK: - Physics Update

    // Detection range for other sprites
    private static let spriteDetectionRange: CGFloat = 20
    private static let spriteAvoidanceChance: CGFloat = 0.7  // 70% chance to turn when sprite detected ahead

    mutating func update(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge], walls: [WindowObserver.Wall] = [], otherSprites: [CGPoint] = [], shouldWander: Bool = true) {
        guard !isDragging else { return }

        // Check if another sprite is ahead and maybe change direction
        if shouldWander {
            checkForSpritesAhead(otherSprites: otherSprites, screenBounds: screenBounds, ledges: ledges)
        }

        switch currentSurface {
        case .falling:
            updateFalling(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges)
        case .floor, .ledge:
            updateHorizontalSurface(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges, walls: walls, shouldWander: shouldWander)
        case .leftWall, .rightWall:
            updateScreenWallClimbing(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges, shouldWander: shouldWander)
        case .windowWall:
            updateWindowWallClimbing(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges, shouldWander: shouldWander)
        case .ceiling:
            updateCeiling(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges, shouldWander: shouldWander)
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private mutating func checkForSpritesAhead(otherSprites: [CGPoint], screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        guard !otherSprites.isEmpty else { return }

        // Only check when actively moving toward a target
        let movingRight = velocity.x > 2
        let movingLeft = velocity.x < -2
        let movingUp = velocity.y > 2
        let movingDown = velocity.y < -2

        guard movingRight || movingLeft || movingUp || movingDown else { return }

        for otherPos in otherSprites {
            let dx = otherPos.x - position.x
            let dy = otherPos.y - position.y
            let distance = sqrt(dx * dx + dy * dy)

            // Skip if too far
            guard distance < Self.spriteDetectionRange else { continue }

            // Check if the other sprite is ahead of us in our movement direction
            var isAhead = false

            switch currentSurface {
            case .floor, .ledge, .ceiling:
                // Horizontal movement - check if sprite is ahead horizontally and at similar height
                let similarHeight = abs(dy) < 50
                if similarHeight {
                    if movingRight && dx > 0 && dx < Self.spriteDetectionRange {
                        isAhead = true
                    } else if movingLeft && dx < 0 && abs(dx) < Self.spriteDetectionRange {
                        isAhead = true
                    }
                }
            case .leftWall, .rightWall, .windowWall:
                // Vertical movement on walls - check if sprite is ahead vertically
                let similarX = abs(dx) < 50
                if similarX {
                    if movingUp && dy > 0 && dy < Self.spriteDetectionRange {
                        isAhead = true
                    } else if movingDown && dy < 0 && abs(dy) < Self.spriteDetectionRange {
                        isAhead = true
                    }
                }
            case .falling:
                break  // Don't change direction while falling
            }

            if isAhead && CGFloat.random(in: 0...1) < Self.spriteAvoidanceChance {
                // Change direction - pick a new target away from this sprite
                pickTargetAwayFrom(otherPos, screenBounds: screenBounds, ledges: ledges)
                return
            }
        }
    }

    private mutating func pickTargetAwayFrom(_ avoidPos: CGPoint, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        let dx = avoidPos.x - position.x

        switch currentSurface {
        case .floor:
            // Pick target on opposite side
            if dx > 0 {
                // Other sprite is to the right, go left
                targetPosition = CGFloat.random(in: (screenBounds.minX + 60)...(position.x - 20))
            } else {
                // Other sprite is to the left, go right
                targetPosition = CGFloat.random(in: (position.x + 20)...(screenBounds.maxX - 60))
            }
        case .ledge:
            // Stay on ledge but move away
            let minX = (currentLedgeMinX ?? screenBounds.minX) + 20
            let maxX = (currentLedgeMaxX ?? screenBounds.maxX) - 20
            if dx > 0 && minX < position.x - 10 {
                targetPosition = CGFloat.random(in: minX...(position.x - 10))
            } else if dx < 0 && maxX > position.x + 10 {
                targetPosition = CGFloat.random(in: (position.x + 10)...maxX)
            }
        case .ceiling:
            if dx > 0 {
                targetPosition = CGFloat.random(in: (screenBounds.minX + 60)...(position.x - 20))
            } else {
                targetPosition = CGFloat.random(in: (position.x + 20)...(screenBounds.maxX - 60))
            }
        case .leftWall, .rightWall, .windowWall:
            let dy = avoidPos.y - position.y
            if dy > 0 {
                // Other sprite is above, go down
                targetPosition = CGFloat.random(in: (groundY + 50)...(position.y - 20))
            } else {
                // Other sprite is below, go up
                targetPosition = CGFloat.random(in: (position.y + 20)...(screenBounds.maxY - 100))
            }
        case .falling:
            break
        }

        lastTargetChange = Date()
    }

    private mutating func updateFalling(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // Apply gravity
        velocity.y += Self.gravity * deltaTime
        velocity.y = max(velocity.y, Self.maxFallSpeed)

        // Air friction
        let airFriction: CGFloat = 0.95
        velocity.x *= airFriction

        // Update position
        position.x += velocity.x * deltaTime
        position.y += velocity.y * deltaTime

        // Check for landing on ledges
        if velocity.y < 0 {
            for ledge in ledges where ledge.contains(x: position.x) {
                if position.y <= ledge.y && position.y > ledge.y - 30 {
                    landOnLedge(ledge: ledge)
                    return
                }
            }

            // Check ground
            if position.y <= groundY {
                position.y = groundY
                velocity = .zero
                currentSurface = .floor
                currentLedgeY = groundY
                currentLedgeMinX = screenBounds.minX
                currentLedgeMaxX = screenBounds.maxX
            }
        }

        // Screen bounds
        position.x = max(screenBounds.minX + Self.edgeMargin, min(screenBounds.maxX - Self.edgeMargin, position.x))
    }

    private mutating func landOnLedge(ledge: WindowObserver.Ledge) {
        position.y = ledge.y
        velocity = .zero
        currentSurface = .ledge
        currentLedgeY = ledge.y
        currentLedgeMinX = ledge.minX
        currentLedgeMaxX = ledge.maxX
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private mutating func updateHorizontalSurface(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge], walls: [WindowObserver.Wall], shouldWander: Bool) {
        // Wander behavior (only when enabled)
        if shouldWander {
            updateWander(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges)
        } else {
            velocity.x = 0
        }

        // Update position
        position.x += velocity.x * deltaTime

        // Check for edge transitions
        let leftEdge = currentSurface == .floor ? screenBounds.minX + Self.edgeMargin : (currentLedgeMinX ?? screenBounds.minX) + 10
        let rightEdge = currentSurface == .floor ? screenBounds.maxX - Self.edgeMargin : (currentLedgeMaxX ?? screenBounds.maxX) - 10

        // Check for window wall collision first (before screen edges)
        // Only when moving horizontally toward a wall
        for wall in walls {
            // Check if our Y position is within the wall's climbable range
            guard wall.contains(y: position.y, margin: 10) else { continue }

            let wallCollisionMargin: CGFloat = 5

            // Moving right and hitting a left wall (the wall is to our right)
            if velocity.x > 0 && wall.side == .left {
                if position.x >= wall.x - wallCollisionMargin && position.x < wall.x + 20 {
                    position.x = wall.x
                    startClimbingWindowWall(wall: wall, screenBounds: screenBounds)
                    return
                }
            }

            // Moving left and hitting a right wall (the wall is to our left)
            if velocity.x < 0 && wall.side == .right {
                if position.x <= wall.x + wallCollisionMargin && position.x > wall.x - 20 {
                    position.x = wall.x
                    startClimbingWindowWall(wall: wall, screenBounds: screenBounds)
                    return
                }
            }
        }

        // At left screen edge - start climbing left wall
        if position.x <= screenBounds.minX + Self.edgeMargin + 5 {
            position.x = screenBounds.minX + Self.edgeMargin
            startClimbingScreenWall(isLeftWall: true, screenBounds: screenBounds)
            return
        }

        // At right screen edge - start climbing right wall
        if position.x >= screenBounds.maxX - Self.edgeMargin - 5 {
            position.x = screenBounds.maxX - Self.edgeMargin
            startClimbingScreenWall(isLeftWall: false, screenBounds: screenBounds)
            return
        }

        // Check if we've walked off the ledge or if the ledge no longer exists
        if currentSurface == .ledge {
            // First check if we walked off horizontally
            if position.x < leftEdge || position.x > rightEdge {
                currentSurface = .falling
                currentLedgeY = nil
                currentLedgeMinX = nil
                currentLedgeMaxX = nil
            } else if let ledgeY = currentLedgeY {
                // Verify the ledge still exists (window may have moved)
                let ledgeStillExists = ledges.contains { ledge in
                    abs(ledge.y - ledgeY) < 10 && ledge.contains(x: position.x)
                }
                if !ledgeStillExists {
                    currentSurface = .falling
                    currentLedgeY = nil
                    currentLedgeMinX = nil
                    currentLedgeMaxX = nil
                }
            }
        }

        // Keep on ground if on floor
        if currentSurface == .floor {
            position.y = groundY
        }
    }

    private mutating func startClimbingScreenWall(isLeftWall: Bool, screenBounds: CGRect) {
        currentSurface = isLeftWall ? .leftWall : .rightWall
        velocity = CGPoint(x: 0, y: Self.climbSpeed)  // Start climbing up
        currentLedgeY = nil
        currentLedgeMinX = nil
        currentLedgeMaxX = nil
        currentWallX = nil
        currentWallMinY = nil
        currentWallMaxY = nil
        targetPosition = screenBounds.maxY - 60  // Target near top
        lastTargetChange = Date()
    }

    private mutating func startClimbingWindowWall(wall: WindowObserver.Wall, screenBounds: CGRect) {
        currentSurface = .windowWall(x: wall.x, side: wall.side)
        velocity = CGPoint(x: 0, y: Self.climbSpeed)  // Start climbing up
        currentLedgeY = nil
        currentLedgeMinX = nil
        currentLedgeMaxX = nil
        currentWallX = wall.x
        currentWallMinY = wall.minY
        currentWallMaxY = wall.maxY
        targetPosition = wall.maxY - 10  // Target near top of wall
        lastTargetChange = Date()
    }

    private mutating func updateScreenWallClimbing(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge], shouldWander: Bool) {
        let isLeftWall = currentSurface == .leftWall

        // Wander vertically on wall (only when enabled)
        if shouldWander {
            updateWallWander(deltaTime: deltaTime, screenBounds: screenBounds)
        } else {
            velocity.y = 0
        }

        // Update position
        position.y += velocity.y * deltaTime

        // Keep against wall
        position.x = isLeftWall ? screenBounds.minX + Self.edgeMargin : screenBounds.maxX - Self.edgeMargin

        // Check for ceiling transition
        let ceilingY = screenBounds.maxY - 50
        if position.y >= ceilingY {
            position.y = ceilingY
            transitionToCeiling(fromLeftWall: isLeftWall, screenBounds: screenBounds)
            return
        }

        // Check for floor transition
        if position.y <= groundY {
            position.y = groundY
            velocity = .zero
            currentSurface = .floor
            currentLedgeY = groundY
            currentLedgeMinX = screenBounds.minX
            currentLedgeMaxX = screenBounds.maxX
            currentWallX = nil
            currentWallMinY = nil
            currentWallMaxY = nil
            targetPosition = position.x
        }
    }

    private mutating func updateWindowWallClimbing(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge], shouldWander: Bool) {
        guard case .windowWall(let wallX, let side) = currentSurface,
              let wallMinY = currentWallMinY,
              let wallMaxY = currentWallMaxY else {
            // Invalid state - fall
            currentSurface = .falling
            return
        }

        // Wander vertically on wall (only when enabled)
        if shouldWander {
            updateWindowWallWander(wallMinY: wallMinY, wallMaxY: wallMaxY)
        } else {
            velocity.y = 0
        }

        // Update position
        position.y += velocity.y * deltaTime

        // Keep against wall
        position.x = wallX

        // Check for top transition - land on the ledge at the top of the wall
        if position.y >= wallMaxY - 5 {
            position.y = wallMaxY
            // Find the ledge at this height
            if let ledge = ledges.first(where: { abs($0.y - wallMaxY) < 10 && $0.contains(x: position.x) }) {
                landOnLedge(ledge: ledge)
            } else {
                // No ledge found, just transition to walking on a virtual surface
                currentSurface = .ledge
                currentLedgeY = wallMaxY
                // Estimate ledge bounds based on wall side
                if side == .left {
                    currentLedgeMinX = wallX
                    currentLedgeMaxX = wallX + 200  // Assume some width
                } else {
                    currentLedgeMinX = wallX - 200
                    currentLedgeMaxX = wallX
                }
            }
            velocity = .zero
            currentWallX = nil
            currentWallMinY = nil
            currentWallMaxY = nil
            targetPosition = position.x
            return
        }

        // Check for bottom transition - land on surface below
        if position.y <= wallMinY + 5 {
            position.y = wallMinY
            velocity = .zero

            // Find what surface is at this Y level
            if let ledge = ledges.first(where: { abs($0.y - wallMinY) < 10 && $0.contains(x: position.x) }) {
                landOnLedge(ledge: ledge)
            } else if wallMinY <= groundY + 10 {
                // At ground level
                currentSurface = .floor
                currentLedgeY = groundY
                currentLedgeMinX = screenBounds.minX
                currentLedgeMaxX = screenBounds.maxX
                position.y = groundY
            } else {
                // No surface found, start falling
                currentSurface = .falling
                currentLedgeY = nil
                currentLedgeMinX = nil
                currentLedgeMaxX = nil
            }

            currentWallX = nil
            currentWallMinY = nil
            currentWallMaxY = nil
            targetPosition = position.x
        }
    }

    private mutating func updateWindowWallWander(wallMinY: CGFloat, wallMaxY: CGFloat) {
        // Occasionally pick new vertical target within wall bounds
        if Date().timeIntervalSince(lastTargetChange) > Self.wanderInterval {
            let margin: CGFloat = 20
            let minTarget = wallMinY + margin
            let maxTarget = wallMaxY - margin
            if maxTarget > minTarget {
                targetPosition = CGFloat.random(in: minTarget...maxTarget)
            } else {
                targetPosition = (wallMinY + wallMaxY) / 2
            }
            lastTargetChange = Date()
        }

        // Move toward target
        let toTarget = targetPosition - position.y
        if abs(toTarget) > 5 {
            let moveDir: CGFloat = toTarget > 0 ? 1 : -1
            velocity.y = moveDir * Self.climbSpeed
        } else {
            velocity.y = 0
        }
    }

    private mutating func transitionToCeiling(fromLeftWall: Bool, screenBounds: CGRect) {
        currentSurface = .ceiling
        velocity = CGPoint(x: fromLeftWall ? Self.moveSpeed : -Self.moveSpeed, y: 0)
        targetPosition = CGFloat.random(in: (screenBounds.minX + 100)...(screenBounds.maxX - 100))
        lastTargetChange = Date()
    }

    private mutating func updateCeiling(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge], shouldWander: Bool) {
        // Wander horizontally on ceiling (only when enabled)
        if shouldWander {
            updateCeilingWander(deltaTime: deltaTime, screenBounds: screenBounds)
        } else {
            velocity.x = 0
        }

        // Update position
        position.x += velocity.x * deltaTime

        // Keep on ceiling
        let ceilingY = screenBounds.maxY - 50
        position.y = ceilingY

        // Check for wall transitions at edges
        if position.x <= screenBounds.minX + Self.edgeMargin + 5 {
            position.x = screenBounds.minX + Self.edgeMargin
            // Start climbing down left wall
            currentSurface = .leftWall
            velocity = CGPoint(x: 0, y: -Self.climbSpeed)
            targetPosition = groundY + 100
            return
        }

        if position.x >= screenBounds.maxX - Self.edgeMargin - 5 {
            position.x = screenBounds.maxX - Self.edgeMargin
            // Start climbing down right wall
            currentSurface = .rightWall
            velocity = CGPoint(x: 0, y: -Self.climbSpeed)
            targetPosition = groundY + 100
            return
        }

        // Check if there's a ledge below we should drop to
        checkForLedgeDrop(screenBounds: screenBounds, ledges: ledges)
    }

    private mutating func checkForLedgeDrop(screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // Find the highest ledge below the ceiling
        let ceilingY = screenBounds.maxY - 50

        for ledge in ledges.sorted(by: { $0.y > $1.y }) {
            // Ledge must be below ceiling
            if ledge.y >= ceilingY - 10 {
                continue
            }

            // Check if we're horizontally over this ledge
            if ledge.contains(x: position.x) {
                // Random chance to drop (so they don't always drop immediately)
                if Bool.random() && Date().timeIntervalSince(lastTargetChange) > 2.0 {
                    // Drop to this ledge
                    currentSurface = .falling
                    velocity = CGPoint(x: 0, y: -50)  // Small initial downward velocity
                    lastTargetChange = Date()
                    return
                }
            }
        }
    }

    private mutating func updateWallWander(deltaTime: CGFloat, screenBounds: CGRect) {
        // Occasionally pick new vertical target
        if Date().timeIntervalSince(lastTargetChange) > Self.wanderInterval {
            targetPosition = CGFloat.random(in: (groundY + 50)...(screenBounds.maxY - 100))
            lastTargetChange = Date()
        }

        // Move toward target
        let toTarget = targetPosition - position.y
        if abs(toTarget) > 5 {
            let moveDir: CGFloat = toTarget > 0 ? 1 : -1
            velocity.y = moveDir * Self.climbSpeed
        } else {
            velocity.y = 0
        }
    }

    private mutating func updateCeilingWander(deltaTime: CGFloat, screenBounds: CGRect) {
        // Occasionally pick new horizontal target
        if Date().timeIntervalSince(lastTargetChange) > Self.wanderInterval {
            targetPosition = CGFloat.random(in: (screenBounds.minX + 100)...(screenBounds.maxX - 100))
            lastTargetChange = Date()
        }

        // Move toward target
        let toTarget = targetPosition - position.x
        if abs(toTarget) > 5 {
            let moveDir: CGFloat = toTarget > 0 ? 1 : -1
            velocity.x = moveDir * Self.moveSpeed
        } else {
            velocity.x = 0
        }
    }

    private mutating func updateWander(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // Occasionally pick new wander target
        if Date().timeIntervalSince(lastTargetChange) > Self.wanderInterval {
            pickNewTarget(screenBounds: screenBounds, ledges: ledges)
            lastTargetChange = Date()
        }

        // Move toward target
        let toTarget = targetPosition - position.x
        if abs(toTarget) > 5 {
            let moveDir: CGFloat = toTarget > 0 ? 1 : -1
            velocity.x = moveDir * Self.moveSpeed
        } else {
            velocity.x = 0
        }
    }

    private mutating func pickNewTarget(screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // If on a window ledge, prefer staying on it but occasionally go to screen edge
        if currentSurface == .ledge, let ledgeY = currentLedgeY {
            if let currentLedge = ledges.first(where: { abs($0.y - ledgeY) < 5 && $0.contains(x: position.x) }) {
                // 30% chance to head toward screen edge to climb
                if CGFloat.random(in: 0...1) < 0.3 {
                    targetPosition = Bool.random() ? screenBounds.minX + Self.edgeMargin : screenBounds.maxX - Self.edgeMargin
                    return
                }

                // Otherwise stay within this ledge with some margin
                let margin: CGFloat = 40
                let minX = currentLedge.minX + margin
                let maxX = currentLedge.maxX - margin

                if maxX > minX {
                    targetPosition = CGFloat.random(in: minX...maxX)
                    return
                }
            }
        }

        // On floor - sometimes head to walls, sometimes wander
        if currentSurface == .floor {
            // 20% chance to head toward a wall
            if CGFloat.random(in: 0...1) < 0.2 {
                targetPosition = Bool.random() ? screenBounds.minX + Self.edgeMargin : screenBounds.maxX - Self.edgeMargin
                return
            }
        }

        // Otherwise use screen bounds for general wandering
        let margin: CGFloat = 60
        targetPosition = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
    }
}
