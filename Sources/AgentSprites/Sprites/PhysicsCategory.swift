import Foundation

/// Bitmask categories for SpriteKit physics collision/contact detection
struct PhysicsCategory {
    static let sprite: UInt32 = 1 << 0
    static let surface: UInt32 = 1 << 1
}

/// Bitmask categories for per-sprite gravity field targeting
struct GravityCategory {
    static let down: UInt32 = 1 << 4
    static let left: UInt32 = 1 << 5
    static let up: UInt32 = 1 << 6
    static let right: UInt32 = 1 << 7
}
