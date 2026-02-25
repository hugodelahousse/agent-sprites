import Foundation
import CoreGraphics

/// Physics simulation for slime sprites with gravity and ledge support
struct SlimePhysics: Sendable {
    var position: CGPoint
    var velocity: CGPoint = .zero
    var groundY: CGFloat

    // Ledge tracking
    var currentLedgeY: CGFloat?

    // Drag state
    var isDragging: Bool = false
    private var dragVelocityHistory: [CGPoint] = []
    private static let velocityHistoryCount = 5

    // Wander behavior
    private var targetX: CGFloat
    private var lastTargetChange: Date = Date()

    // Physics constants
    private static let gravity: CGFloat = -800
    private static let moveSpeed: CGFloat = 35
    private static let maxFallSpeed: CGFloat = -600
    private static let wanderInterval: TimeInterval = 4.0

    init(x: CGFloat, groundY: CGFloat) {
        self.position = CGPoint(x: x, y: groundY)
        self.groundY = groundY
        self.targetX = x
    }

    var isMoving: Bool {
        abs(velocity.x) > 2
    }

    var isFalling: Bool {
        velocity.y < -10 && currentLedgeY == nil
    }

    var horizontalVelocity: CGFloat {
        velocity.x
    }

    // MARK: - Drag Handling

    mutating func startDrag() {
        isDragging = true
        velocity = .zero
        dragVelocityHistory.removeAll()
        currentLedgeY = nil
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

        // Use average velocity from history
        if !dragVelocityHistory.isEmpty {
            let avgVelocity = dragVelocityHistory.reduce(CGPoint.zero) { result, v in
                CGPoint(x: result.x + v.x, y: result.y + v.y)
            }
            let count = CGFloat(dragVelocityHistory.count)
            velocity = CGPoint(
                x: avgVelocity.x / count,
                y: avgVelocity.y / count
            )
        }

        dragVelocityHistory.removeAll()
    }

    // MARK: - Physics Update

    mutating func update(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        guard !isDragging else { return }

        // Apply gravity
        velocity.y += Self.gravity * deltaTime
        velocity.y = max(velocity.y, Self.maxFallSpeed)

        // Update position
        position.x += velocity.x * deltaTime
        position.y += velocity.y * deltaTime

        // Check for landing on ledges
        if velocity.y < 0 {
            // Check window ledges
            for ledge in ledges {
                if ledge.contains(x: position.x) {
                    // Check if we crossed or are at this ledge
                    if position.y <= ledge.y && position.y > ledge.y - 30 {
                        position.y = ledge.y
                        velocity.y = 0
                        currentLedgeY = ledge.y
                        break
                    }
                }
            }

            // Check ground
            if position.y <= groundY {
                position.y = groundY
                velocity.y = 0
                currentLedgeY = groundY
            }
        }

        // Check if we've walked off a ledge
        if let ledgeY = currentLedgeY, ledgeY != groundY {
            // Find if we're still on a ledge at this Y
            let stillOnLedge = ledges.contains { ledge in
                abs(ledge.y - ledgeY) < 5 && ledge.contains(x: position.x)
            }

            if !stillOnLedge {
                // Walked off the edge - start falling
                currentLedgeY = nil
            }
        }

        // Wander behavior only when on a surface
        if currentLedgeY != nil {
            updateWander(deltaTime: deltaTime, screenBounds: screenBounds, ledges: ledges)
        } else {
            // Slight air control
            velocity.x *= 0.99
        }

        // Screen bounds
        let margin: CGFloat = 32
        position.x = max(screenBounds.minX + margin, min(screenBounds.maxX - margin, position.x))

        // Don't go above screen (allow going higher when dragging)
        if !isDragging {
            let topMargin: CGFloat = 50
            position.y = min(screenBounds.maxY - topMargin, position.y)
        }
    }

    private mutating func updateWander(deltaTime: CGFloat, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // Occasionally pick new wander target
        if Date().timeIntervalSince(lastTargetChange) > Self.wanderInterval {
            pickNewTarget(screenBounds: screenBounds, ledges: ledges)
            lastTargetChange = Date()
        }

        // Move toward target
        let toTarget = targetX - position.x
        if abs(toTarget) > 5 {
            let moveDir: CGFloat = toTarget > 0 ? 1 : -1
            velocity.x = moveDir * Self.moveSpeed
        } else {
            velocity.x = 0
        }
    }

    private mutating func pickNewTarget(screenBounds: CGRect, ledges: [WindowObserver.Ledge]) {
        // If on a window ledge, prefer staying on it
        if let ledgeY = currentLedgeY, ledgeY != groundY {
            if let currentLedge = ledges.first(where: { abs($0.y - ledgeY) < 5 && $0.contains(x: position.x) }) {
                // Stay within this ledge with some margin
                let margin: CGFloat = 40
                let minX = currentLedge.minX + margin
                let maxX = currentLedge.maxX - margin

                if maxX > minX {
                    targetX = CGFloat.random(in: minX...maxX)
                    return
                }
            }
        }

        // Otherwise use screen bounds
        let margin: CGFloat = 60
        targetX = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
    }
}
