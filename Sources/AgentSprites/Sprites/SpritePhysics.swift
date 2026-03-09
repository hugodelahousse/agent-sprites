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

/// Wander state for goal-directed movement
enum WanderState: Sendable {
    case walking       // Moving toward target
    case idling        // Resting at destination
    case stuckIdling   // Target became unreachable, idling before picking new one
}
