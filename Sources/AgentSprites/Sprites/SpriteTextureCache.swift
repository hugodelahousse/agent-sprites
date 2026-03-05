import AppKit
import SpriteKit

/// Caches SKTexture instances keyed by NSImage identity (ObjectIdentifier)
/// Avoids recreating textures when the same NSImage reference is reused across frames
@MainActor
final class SpriteTextureCache {
    static let shared = SpriteTextureCache()

    private var cache: [ObjectIdentifier: SKTexture] = [:]

    private init() {}

    /// Get or create a texture for the given image
    /// Uses reference identity — same NSImage object returns the same cached texture
    func texture(for image: NSImage) -> SKTexture {
        let key = ObjectIdentifier(image)
        if let cached = cache[key] {
            return cached
        }

        let texture = SKTexture(image: image)
        texture.filteringMode = .nearest  // Pixel art crispness
        cache[key] = texture
        return texture
    }

    /// Clear the entire cache (e.g. when changing character packs)
    func clear() {
        cache.removeAll()
    }
}
