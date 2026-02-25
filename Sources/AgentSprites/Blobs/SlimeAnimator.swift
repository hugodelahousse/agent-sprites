import Foundation
import AppKit
import AgentSpritesCore

/// Manages animation state and frame timing for a slime sprite
struct SlimeAnimator {
    var currentState: SlimeAnimationState = .idle
    var currentFrame: Int = 0
    var frameTime: Double = 0
    var isMoving: Bool = false
    var facingRight: Bool = true
    var isDragging: Bool = false
    var isFalling: Bool = false

    // Frame timing
    private static let framesPerSecond: Double = 10
    private static let attackFramesPerSecond: Double = 15  // Faster attack animation

    /// Map session status to animation state
    static func animationState(for status: SessionStatus, isMoving: Bool, isDragging: Bool, isFalling: Bool) -> SlimeAnimationState {
        // Dragging always shows attack animation
        if isDragging {
            return .attack
        }

        // Falling shows jump animation
        if isFalling {
            return .jump
        }

        switch status {
        case .idle:
            return isMoving ? .walk : .idle
        case .working:
            return isMoving ? .run : .walk
        case .waitingForInput:
            return .idle
        case .waitingForPermission:
            return .jump    // Bouncy attention-getting
        case .error:
            return .hurt
        case .done:
            return .idle
        }
    }

    /// Update animation, returns true if frame changed
    mutating func update(deltaTime: Double, status: SessionStatus, isMoving: Bool, velocity: CGFloat, isDragging: Bool = false, isFalling: Bool = false) -> Bool {
        // Update facing direction based on velocity
        if abs(velocity) > 1 {
            facingRight = velocity > 0
        }

        self.isMoving = isMoving
        self.isDragging = isDragging
        self.isFalling = isFalling
        let targetState = Self.animationState(for: status, isMoving: isMoving, isDragging: isDragging, isFalling: isFalling)

        // Handle state transitions
        if targetState != currentState {
            currentState = targetState
            currentFrame = 0
            frameTime = 0
            return true
        }

        // Update frame timing (faster for attack animation)
        frameTime += deltaTime
        let fps = currentState == .attack ? Self.attackFramesPerSecond : Self.framesPerSecond
        let frameDuration = 1.0 / fps

        if frameTime >= frameDuration {
            frameTime -= frameDuration

            let spriteSheet = SlimeSpriteManager.shared.spriteSheet(for: currentState)
            let frameCount = spriteSheet?.frameCount ?? 1

            currentFrame = (currentFrame + 1) % frameCount
            return true
        }

        return false
    }

    /// Get current frame image
    var currentImage: NSImage? {
        let spriteSheet = SlimeSpriteManager.shared.spriteSheet(for: currentState)
        return spriteSheet?.frame(at: currentFrame)
    }
}
