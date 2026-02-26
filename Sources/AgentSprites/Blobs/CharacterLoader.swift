import AppKit
import Foundation

// MARK: - JSON Models

struct CharacterDefinition: Codable {
    let id: String
    let name: String
    let frameSize: [Int]  // [width, height]
    let scale: Double
    let defaultFps: Double?
    let animations: [String: AnimationDefinition]
    let states: [String: String]

    var frameSizeValue: CGSize {
        CGSize(width: frameSize[0], height: frameSize[1])
    }
}

struct AnimationDefinition: Codable {
    let file: String
    let frames: Int
    let origin: [Int]?  // [x, y], defaults to [0, 0]
    let fps: Double?
    let loop: Bool?
    let vertical: Bool?  // If true, frames are stacked vertically instead of horizontally

    var originPoint: CGPoint {
        guard let origin = origin, origin.count >= 2 else {
            return .zero
        }
        return CGPoint(x: origin[0], y: origin[1])
    }
}

struct SpritesConfig: Codable {
    let mode: String  // "characters" or "hueRotate"
    let characters: [String]?  // For "characters" mode
    let character: String?  // For "hueRotate" mode
}

// MARK: - SpriteCharacter

/// A loaded character with all its animations ready to use
final class SpriteCharacter {
    let definition: CharacterDefinition
    private var animationCache: [String: SpriteAnimation] = [:]
    private let basePath: String

    init(definition: CharacterDefinition, basePath: String) {
        self.definition = definition
        self.basePath = basePath
    }

    /// Get animation for a given state
    func animation(for state: String) -> SpriteAnimation? {
        guard let animationName = definition.states[state] else {
            return nil
        }
        return animation(named: animationName)
    }

    /// Get animation by name
    func animation(named name: String) -> SpriteAnimation? {
        if let cached = animationCache[name] {
            return cached
        }

        guard let animDef = definition.animations[name] else {
            return nil
        }

        let filePath = (basePath as NSString).appendingPathComponent(animDef.file)
        guard let animation = SpriteAnimation(
            filePath: filePath,
            frameSize: definition.frameSizeValue,
            frameCount: animDef.frames,
            origin: animDef.originPoint,
            fps: animDef.fps ?? definition.defaultFps ?? 10,
            loops: animDef.loop ?? true,
            vertical: animDef.vertical ?? false
        ) else {
            return nil
        }

        animationCache[name] = animation
        return animation
    }

    var scale: Double { definition.scale }
    var id: String { definition.id }
    var name: String { definition.name }
}

// MARK: - Sprite Animation

/// A single animation loaded from a sprite sheet
final class SpriteAnimation {
    let frames: [NSImage]
    let frameSize: CGSize
    let fps: Double
    let loops: Bool

    init?(filePath: String, frameSize: CGSize, frameCount: Int, origin: CGPoint, fps: Double, loops: Bool, vertical: Bool = false) {
        guard let image = NSImage(contentsOfFile: filePath) else {
            return nil
        }

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        self.frameSize = frameSize
        self.fps = fps
        self.loops = loops

        var extractedFrames: [NSImage] = []
        for i in 0..<frameCount {
            let rect: CGRect
            if vertical {
                // Frames stacked vertically
                rect = CGRect(
                    x: origin.x,
                    y: origin.y + CGFloat(i) * frameSize.height,
                    width: frameSize.width,
                    height: frameSize.height
                )
            } else {
                // Frames laid out horizontally (default)
                rect = CGRect(
                    x: origin.x + CGFloat(i) * frameSize.width,
                    y: origin.y,
                    width: frameSize.width,
                    height: frameSize.height
                )
            }

            if let frameCG = cgImage.cropping(to: rect) {
                let frameImage = NSImage(cgImage: frameCG, size: frameSize)
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

// MARK: - Character Pack

/// Represents an available character pack (folder)
struct CharacterPack: Identifiable, Hashable {
    let id: String  // folder name
    let name: String  // display name
    let characterCount: Int
    let isSingleCharacter: Bool  // true if it's a single character.json pack
}

// MARK: - Character Manager

/// Manages loading and providing characters
final class CharacterManager {
    static let shared = CharacterManager()

    private static let selectedPackKey = "SelectedCharacterPack"

    private var characters: [String: SpriteCharacter] = [:]
    private var config: SpritesConfig?
    private var characterOrder: [String] = []
    private(set) var availablePacks: [CharacterPack] = []
    private(set) var selectedPackId: String?

    private init() {
        scanAvailablePacks()
        loadSelectedPack()
    }

    static var charactersDirectory: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".agentsprites/characters")
    }

    /// Scan for all available character packs
    private func scanAvailablePacks() {
        let basePath = Self.charactersDirectory
        var packs: [CharacterPack] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: basePath) else {
            return
        }

        for item in contents {
            let itemPath = (basePath as NSString).appendingPathComponent(item)

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: itemPath, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            // Check for character.json (single character pack)
            let singleJsonPath = (itemPath as NSString).appendingPathComponent("character.json")
            if FileManager.default.fileExists(atPath: singleJsonPath) {
                // Read to get display name
                if let data = FileManager.default.contents(atPath: singleJsonPath),
                   let definition = try? JSONDecoder().decode(CharacterDefinition.self, from: data) {
                    packs.append(CharacterPack(
                        id: item,
                        name: definition.name,
                        characterCount: 1,
                        isSingleCharacter: true
                    ))
                }
                continue
            }

            // Check for multiple {name}.json files (multi-character pack)
            if let subContents = try? FileManager.default.contentsOfDirectory(atPath: itemPath) {
                let jsonFiles = subContents.filter { $0.hasSuffix(".json") }
                if !jsonFiles.isEmpty {
                    // Use capitalized folder name as display name
                    let displayName = item.prefix(1).uppercased() + item.dropFirst()
                    packs.append(CharacterPack(
                        id: item,
                        name: displayName,
                        characterCount: jsonFiles.count,
                        isSingleCharacter: false
                    ))
                }
            }
        }

        availablePacks = packs.sorted { $0.name < $1.name }
    }

    /// Load the selected pack from UserDefaults or use default
    private func loadSelectedPack() {
        let savedPackId = UserDefaults.standard.string(forKey: Self.selectedPackKey)

        // Use saved pack if it exists, otherwise use first available pack
        if let savedPackId = savedPackId, availablePacks.contains(where: { $0.id == savedPackId }) {
            selectPack(savedPackId)
        } else if let firstPack = availablePacks.first {
            selectPack(firstPack.id)
        }
    }

    /// Select a character pack by ID
    func selectPack(_ packId: String) {
        guard availablePacks.contains(where: { $0.id == packId }) else { return }

        selectedPackId = packId
        UserDefaults.standard.set(packId, forKey: Self.selectedPackKey)

        // Clear and reload characters for this pack
        characters.removeAll()
        characterOrder.removeAll()
        config = nil

        loadCharactersFromPack(packId)
    }

    private func loadCharactersFromPack(_ packId: String) {
        let packPath = (Self.charactersDirectory as NSString).appendingPathComponent(packId)

        // Check for single character pack
        let singleJsonPath = (packPath as NSString).appendingPathComponent("character.json")
        if let data = FileManager.default.contents(atPath: singleJsonPath),
           let definition = try? JSONDecoder().decode(CharacterDefinition.self, from: data) {
            let character = SpriteCharacter(definition: definition, basePath: packPath)
            characters[definition.id] = character
            characterOrder = [definition.id]
            // Single character pack uses hue rotation mode
            config = SpritesConfig(mode: "hueRotate", characters: nil, character: definition.id)
            return
        }

        // Multi-character pack - load all json files
        guard let subContents = try? FileManager.default.contentsOfDirectory(atPath: packPath) else {
            return
        }

        var loadedCharIds: [String] = []
        for subItem in subContents where subItem.hasSuffix(".json") {
            let jsonPath = (packPath as NSString).appendingPathComponent(subItem)
            if let data = FileManager.default.contents(atPath: jsonPath),
               let definition = try? JSONDecoder().decode(CharacterDefinition.self, from: data) {
                let character = SpriteCharacter(definition: definition, basePath: packPath)
                characters[definition.id] = character
                loadedCharIds.append(definition.id)
            }
        }

        characterOrder = loadedCharIds.sorted()
        // Multi-character pack uses random character mode
        config = SpritesConfig(mode: "randomCharacter", characters: characterOrder, character: nil)
    }

    /// Get character for a blob at a given index (for sequential mode)
    func character(forIndex index: Int) -> SpriteCharacter? {
        guard !characterOrder.isEmpty else { return nil }
        let charId = characterOrder[index % characterOrder.count]
        return characters[charId]
    }

    /// Get character based on path hash (for randomCharacter mode)
    func character(forPath path: String) -> SpriteCharacter? {
        guard !characterOrder.isEmpty else { return nil }

        // Use djb2 hash for deterministic selection
        var hash: UInt64 = 5381
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }

        let index = Int(hash % UInt64(characterOrder.count))
        let charId = characterOrder[index]
        return characters[charId]
    }

    /// Whether we should use hue rotation for differentiation
    var usesHueRotation: Bool {
        config?.mode == "hueRotate"
    }

    /// Whether character selection is based on path hash
    var usesRandomCharacter: Bool {
        config?.mode == "randomCharacter"
    }

    /// All available character IDs
    var availableCharacters: [String] {
        characterOrder
    }

    /// Get character by ID directly
    func character(byId id: String) -> SpriteCharacter? {
        characters[id]
    }
}
