import Foundation
import CoreGraphics

/// Extracted wander state machine from SpritePhysics
/// Produces desired velocity vectors; the coordinator applies them to the physics body
struct WanderBehavior {
    /// Wander state
    var wanderState: WanderState = .idling

    /// Target position along the movement axis
    var targetPosition: CGFloat

    /// Idle timing
    private var idleStartTime: CFAbsoluteTime = 0
    private var idleInterval: TimeInterval = Self.randomIdleInterval()

    /// Frame counter for throttling expensive checks
    var frameCount: UInt32 = 0

    // Physics constants (matching original SpritePhysics values)
    static let moveSpeed: CGFloat = 35
    static let climbSpeed: CGFloat = 30
    private static let arrivalThreshold: CGFloat = 5

    // Sprite avoidance
    private static let spriteDetectionRange: CGFloat = 20
    private static let spriteDetectionRangeSquared: CGFloat = 20 * 20
    private static let spriteAvoidanceChance: CGFloat = 0.7

    private static func randomIdleInterval() -> TimeInterval {
        TimeInterval.random(in: 60...120)
    }

    init(startX: CGFloat) {
        self.targetPosition = startX
        self.idleStartTime = CFAbsoluteTimeGetCurrent()
    }

    /// Context for wander update
    struct UpdateContext {
        let surface: SpriteSurface
        let position: CGPoint
        let screenBounds: CGRect
        let ledges: [WindowObserver.Ledge]
        let walls: [WindowObserver.Wall]
        let wallMinY: CGFloat?
        let wallMaxY: CGFloat?
        let groundY: CGFloat
        let ledgeY: CGFloat?
        let shouldWander: Bool
    }

    /// Returns desired speed along the primary movement axis.
    /// For floor/ledge/ceiling: horizontal speed. For walls: vertical speed.
    mutating func update(context ctx: UpdateContext) -> CGFloat {
        let surface = ctx.surface
        let position = ctx.position
        let screenBounds = ctx.screenBounds
        let ledges = ctx.ledges
        let shouldWander = ctx.shouldWander
        guard shouldWander else { return 0 }

        switch surface {
        case .floor, .ledge:
            return updateHorizontalWander(position: position, screenBounds: screenBounds, ledges: ledges, surface: surface, ledgeY: ctx.ledgeY)
        case .ceiling:
            return updateCeilingWander(position: position, screenBounds: screenBounds)
        case .leftWall, .rightWall:
            return updateWallWander(position: position, screenBounds: screenBounds, groundY: ctx.groundY)
        case .windowWall:
            if let minY = ctx.wallMinY, let maxY = ctx.wallMaxY {
                return updateWindowWallWander(position: position, wallMinY: minY, wallMaxY: maxY)
            }
            return 0
        case .falling:
            return 0
        }
    }

    // MARK: - Sprite Avoidance

    /// Context for sprite avoidance check
    struct AvoidanceContext {
        let surface: SpriteSurface
        let position: CGPoint
        let velocity: CGPoint
        let otherSprites: [CGPoint]
        let screenBounds: CGRect
        let ledges: [WindowObserver.Ledge]
        let groundY: CGFloat
        let ledgeMinX: CGFloat?
        let ledgeMaxX: CGFloat?
    }

    // Check for sprites ahead and potentially change direction. Called every 10th frame.
    // swiftlint:disable:next cyclomatic_complexity
    mutating func checkForSpritesAhead(context ctx: AvoidanceContext) {
        let surface = ctx.surface
        let position = ctx.position
        let velocity = ctx.velocity
        let otherSprites = ctx.otherSprites
        guard !otherSprites.isEmpty else { return }

        let movingRight = velocity.x > 2
        let movingLeft = velocity.x < -2
        let movingUp = velocity.y > 2
        let movingDown = velocity.y < -2
        guard movingRight || movingLeft || movingUp || movingDown else { return }

        for otherPos in otherSprites {
            let dx = otherPos.x - position.x
            let dy = otherPos.y - position.y
            let distanceSquared = dx * dx + dy * dy
            guard distanceSquared < Self.spriteDetectionRangeSquared else { continue }

            var isAhead = false

            switch surface {
            case .floor, .ledge, .ceiling:
                let similarHeight = abs(dy) < 50
                if similarHeight {
                    if movingRight && dx > 0 && dx < Self.spriteDetectionRange {
                        isAhead = true
                    } else if movingLeft && dx < 0 && abs(dx) < Self.spriteDetectionRange {
                        isAhead = true
                    }
                }
            case .leftWall, .rightWall, .windowWall:
                let similarX = abs(dx) < 50
                if similarX {
                    if movingUp && dy > 0 && dy < Self.spriteDetectionRange {
                        isAhead = true
                    } else if movingDown && dy < 0 && abs(dy) < Self.spriteDetectionRange {
                        isAhead = true
                    }
                }
            case .falling:
                break
            }

            if isAhead && CGFloat.random(in: 0...1) < Self.spriteAvoidanceChance {
                pickTargetAwayFrom(otherPos, surface: surface, position: position, screenBounds: ctx.screenBounds, ledges: ctx.ledges, groundY: ctx.groundY, ledgeMinX: ctx.ledgeMinX, ledgeMaxX: ctx.ledgeMaxX)
                return
            }
        }
    }

    // MARK: - Target Picking

    // swiftlint:disable:next function_parameter_count
    mutating func pickNewTarget(surface: SpriteSurface, position: CGPoint, screenBounds: CGRect, ledges: [WindowObserver.Ledge], ledgeY: CGFloat?, edgeMargin: CGFloat) {
        if surface == .ledge, let ledgeY {
            if let currentLedge = ledges.first(where: { abs($0.y - ledgeY) < 5 && $0.contains(x: position.x) }) {
                // 30% chance to head toward screen edge to climb
                if CGFloat.random(in: 0...1) < 0.3 {
                    targetPosition = Bool.random() ? screenBounds.minX + edgeMargin : screenBounds.maxX - edgeMargin
                    return
                }

                let margin: CGFloat = 40
                let minX = currentLedge.minX + margin
                let maxX = currentLedge.maxX - margin
                if maxX > minX {
                    targetPosition = CGFloat.random(in: minX...maxX)
                    return
                }
            }
        }

        if surface == .floor {
            // 20% chance to head toward a wall
            if CGFloat.random(in: 0...1) < 0.2 {
                targetPosition = Bool.random() ? screenBounds.minX + edgeMargin : screenBounds.maxX - edgeMargin
                return
            }
        }

        let margin: CGFloat = 60
        targetPosition = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
    }

    /// Check if there's a ledge below the ceiling to drop to
    mutating func checkForLedgeDrop(position: CGPoint, screenBounds: CGRect, ledges: [WindowObserver.Ledge]) -> Bool {
        let ceilingY = screenBounds.maxY - 50
        for ledge in ledges.sorted(by: { $0.y > $1.y }) {
            if ledge.y >= ceilingY - 10 { continue }
            if ledge.contains(x: position.x) {
                if Bool.random() && wanderState != .walking {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Idle

    mutating func startIdling(stuck: Bool) {
        wanderState = stuck ? .stuckIdling : .idling
        idleStartTime = CFAbsoluteTimeGetCurrent()
        idleInterval = Self.randomIdleInterval()
    }

    func hasIdleExpired() -> Bool {
        CFAbsoluteTimeGetCurrent() - idleStartTime >= idleInterval
    }

    // MARK: - Private Wander Updates

    private mutating func updateHorizontalWander(position: CGPoint, screenBounds: CGRect, ledges: [WindowObserver.Ledge], surface: SpriteSurface, ledgeY: CGFloat?) -> CGFloat {
        switch wanderState {
        case .idling, .stuckIdling:
            if hasIdleExpired() {
                pickNewTarget(surface: surface, position: position, screenBounds: screenBounds, ledges: ledges, ledgeY: ledgeY, edgeMargin: 32)
                wanderState = .walking
            }
            return 0
        case .walking:
            let toTarget = targetPosition - position.x
            if abs(toTarget) > Self.arrivalThreshold {
                return (toTarget > 0 ? 1 : -1) * Self.moveSpeed
            } else {
                startIdling(stuck: false)
                return 0
            }
        }
    }

    private mutating func updateCeilingWander(position: CGPoint, screenBounds: CGRect) -> CGFloat {
        switch wanderState {
        case .idling, .stuckIdling:
            if hasIdleExpired() {
                targetPosition = CGFloat.random(in: (screenBounds.minX + 100)...(screenBounds.maxX - 100))
                wanderState = .walking
            }
            return 0
        case .walking:
            let toTarget = targetPosition - position.x
            if abs(toTarget) > Self.arrivalThreshold {
                return (toTarget > 0 ? 1 : -1) * Self.moveSpeed
            } else {
                startIdling(stuck: false)
                return 0
            }
        }
    }

    private mutating func updateWallWander(position: CGPoint, screenBounds: CGRect, groundY: CGFloat) -> CGFloat {
        switch wanderState {
        case .idling, .stuckIdling:
            if hasIdleExpired() {
                let lo = groundY + 50
                let hi = screenBounds.maxY - 100
                if lo < hi {
                    targetPosition = CGFloat.random(in: lo...hi)
                }
                wanderState = .walking
            }
            return 0
        case .walking:
            let toTarget = targetPosition - position.y
            if abs(toTarget) > Self.arrivalThreshold {
                return (toTarget > 0 ? 1 : -1) * Self.climbSpeed
            } else {
                startIdling(stuck: false)
                return 0
            }
        }
    }

    private mutating func updateWindowWallWander(position: CGPoint, wallMinY: CGFloat, wallMaxY: CGFloat) -> CGFloat {
        switch wanderState {
        case .idling, .stuckIdling:
            if hasIdleExpired() {
                let margin: CGFloat = 20
                let minTarget = wallMinY + margin
                let maxTarget = wallMaxY - margin
                if maxTarget > minTarget {
                    targetPosition = CGFloat.random(in: minTarget...maxTarget)
                } else {
                    targetPosition = (wallMinY + wallMaxY) / 2
                }
                wanderState = .walking
            }
            return 0
        case .walking:
            let toTarget = targetPosition - position.y
            if abs(toTarget) > Self.arrivalThreshold {
                return (toTarget > 0 ? 1 : -1) * Self.climbSpeed
            } else {
                startIdling(stuck: false)
                return 0
            }
        }
    }

    // MARK: - Private Avoidance

    // swiftlint:disable:next function_parameter_count cyclomatic_complexity
    private mutating func pickTargetAwayFrom(
        _ avoidPos: CGPoint,
        surface: SpriteSurface,
        position: CGPoint,
        screenBounds: CGRect,
        ledges: [WindowObserver.Ledge],
        groundY: CGFloat,
        ledgeMinX: CGFloat?,
        ledgeMaxX: CGFloat?
    ) {
        let dx = avoidPos.x - position.x

        switch surface {
        case .floor:
            if dx > 0 {
                let lo = screenBounds.minX + 60
                let hi = position.x - 20
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            } else {
                let lo = position.x + 20
                let hi = screenBounds.maxX - 60
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            }
        case .ledge:
            let minX = (ledgeMinX ?? screenBounds.minX) + 20
            let maxX = (ledgeMaxX ?? screenBounds.maxX) - 20
            if dx > 0 && minX < position.x - 10 {
                targetPosition = CGFloat.random(in: minX...(position.x - 10))
            } else if dx < 0 && maxX > position.x + 10 {
                targetPosition = CGFloat.random(in: (position.x + 10)...maxX)
            }
        case .ceiling:
            if dx > 0 {
                let lo = screenBounds.minX + 60
                let hi = position.x - 20
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            } else {
                let lo = position.x + 20
                let hi = screenBounds.maxX - 60
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            }
        case .leftWall, .rightWall, .windowWall:
            let dy = avoidPos.y - position.y
            if dy > 0 {
                let lo = groundY + 50
                let hi = position.y - 20
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            } else {
                let lo = position.y + 20
                let hi = screenBounds.maxY - 100
                if lo < hi { targetPosition = CGFloat.random(in: lo...hi) }
            }
        case .falling:
            break
        }

        wanderState = .walking
    }
}
