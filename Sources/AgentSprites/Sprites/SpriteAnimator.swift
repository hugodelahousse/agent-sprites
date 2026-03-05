import Foundation
import AppKit
import AgentSpritesCore

/// Manages animation state and frame timing for a character sprite
struct SpriteAnimator {
    var currentState: String = "idle"
    var currentFrame: Int = 0
    var frameTime: Double = 0
    var isMoving: Bool = false
    var facingRight: Bool = true
    var isDragging: Bool = false
    var isFalling: Bool = false

    let character: SpriteCharacter

    init(character: SpriteCharacter) {
        self.character = character
    }

    /// Map session status to state name
    static func stateName(for status: SessionStatus, isMoving: Bool, isDragging: Bool, isFalling: Bool) -> String {
        if isDragging {
            return "dragging"
        }

        if isFalling {
            return "falling"
        }

        if isMoving {
            return "moving"
        }

        switch status {
        case .idle:
            return "idle"
        case .working:
            return "working"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForPermission:
            return "waitingForPermission"
        case .error:
            return "error"
        case .done:
            return "done"
        }
    }

    /// Update animation, returns true if frame changed
    mutating func update(deltaTime: Double, status: SessionStatus, isMoving: Bool, velocity: CGFloat, isDragging: Bool = false, isFalling: Bool = false, isClimbing: Bool = false, verticalVelocity: CGFloat = 0) -> Bool {
        // Update facing direction based on velocity
        if isClimbing {
            if abs(verticalVelocity) > 1 {
                facingRight = verticalVelocity > 0
            }
        } else if abs(velocity) > 1 {
            facingRight = velocity > 0
        }

        self.isMoving = isMoving
        self.isDragging = isDragging
        self.isFalling = isFalling
        let targetState = Self.stateName(for: status, isMoving: isMoving, isDragging: isDragging, isFalling: isFalling)

        // Handle state transitions
        if targetState != currentState {
            currentState = targetState
            currentFrame = 0
            frameTime = 0
            return true
        }

        // Update frame timing
        frameTime += deltaTime
        let animation = character.animation(for: currentState)
        let fps = animation?.fps ?? 10
        let frameDuration = 1.0 / fps

        if frameTime >= frameDuration {
            // Use truncatingRemainder to prevent frameTime accumulation when
            // render FPS is lower than animation FPS (e.g. during 4fps throttle).
            // This correctly skips frames rather than queuing them for rapid playback.
            let framesAdvanced = Int(frameTime / frameDuration)
            frameTime = frameTime.truncatingRemainder(dividingBy: frameDuration)

            let frameCount = animation?.frameCount ?? 1
            currentFrame = (currentFrame + framesAdvanced) % frameCount
            return true
        }

        return false
    }

    /// Get current frame image
    var currentImage: NSImage? {
        let animation = character.animation(for: currentState)
        return animation?.frame(at: currentFrame)
    }
}
