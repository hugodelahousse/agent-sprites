import AppKit
import CoreGraphics

/// Loads and manages sprite sheet animations
final class SpriteSheet {
    let frames: [NSImage]
    let frameSize: CGSize

    init?(named name: String, frameWidth: Int = 128, frameHeight: Int = 128) {
        // Try to load from Resources folder
        let resourcePath = Bundle.main.resourcePath ?? ""
        let spritesPath = (resourcePath as NSString).appendingPathComponent("Sprites")
        let filePath = (spritesPath as NSString).appendingPathComponent("\(name).png")

        // Also try direct path for development
        let devPath = "/Users/hugo/projects/agent-sprites/Sources/AgentSprites/Resources/Sprites/\(name).png"

        guard let image = NSImage(contentsOfFile: filePath) ?? NSImage(contentsOfFile: devPath) else {
            return nil
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.frameSize = CGSize(width: frameWidth, height: frameHeight)
        let frameCount = cgImage.width / frameWidth

        var extractedFrames: [NSImage] = []
        for i in 0..<frameCount {
            let rect = CGRect(
                x: i * frameWidth,
                y: 0,
                width: frameWidth,
                height: frameHeight
            )

            if let frameCG = cgImage.cropping(to: rect) {
                let frameImage = NSImage(cgImage: frameCG, size: NSSize(width: frameWidth, height: frameHeight))
                extractedFrames.append(frameImage)
            }
        }

        self.frames = extractedFrames
    }

    var frameCount: Int { frames.count }

    func frame(at index: Int) -> NSImage? {
        guard index >= 0 && index < frames.count else { return nil }
        return frames[index]
    }
}

/// Manages all slime sprite sheets
final class SlimeSpriteManager {
    static let shared = SlimeSpriteManager()

    private(set) var idle: SpriteSheet?
    private(set) var walk: SpriteSheet?
    private(set) var run: SpriteSheet?
    private(set) var jump: SpriteSheet?
    private(set) var hurt: SpriteSheet?
    private(set) var dead: SpriteSheet?
    private(set) var attack1: SpriteSheet?

    private init() {
        loadSprites()
    }

    func loadSprites() {
        idle = SpriteSheet(named: "Idle")
        walk = SpriteSheet(named: "Walk")
        run = SpriteSheet(named: "Run")
        jump = SpriteSheet(named: "Jump")
        hurt = SpriteSheet(named: "Hurt")
        dead = SpriteSheet(named: "Dead")
        attack1 = SpriteSheet(named: "Attack_1")
    }

    /// Get the appropriate sprite sheet for a session status
    func spriteSheet(for status: SlimeAnimationState) -> SpriteSheet? {
        switch status {
        case .idle:
            return idle
        case .walk:
            return walk
        case .run:
            return run
        case .jump:
            return jump
        case .hurt:
            return hurt
        case .dead:
            return dead
        case .attack:
            return attack1
        }
    }
}

/// Animation states for the slime
enum SlimeAnimationState {
    case idle
    case walk
    case run
    case jump
    case hurt
    case dead
    case attack
}
