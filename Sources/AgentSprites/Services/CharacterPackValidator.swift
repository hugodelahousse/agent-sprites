import Foundation
import AppKit
import os

// MARK: - Validation Result

struct PackValidationResult {
    let isValid: Bool
    let errors: [String]        // Critical: prevents import
    let warnings: [String]      // Non-critical: allow import with warning
    let packInfo: PackInfo?     // nil if couldn't parse
}

struct PackInfo {
    let id: String
    let name: String
    let isSingleCharacter: Bool
    let characterCount: Int
    let animationNames: [String]
}

// MARK: - Validator

enum CharacterPackValidator {
    private static let logger = Logger(subsystem: "com.agentsprites.app", category: "PackValidator")

    /// All states that must be mapped in a character definition
    static let requiredStates = [
        "idle", "working", "moving", "waitingForInput",
        "waitingForPermission", "error", "done", "dragging", "falling"
    ]

    /// Validate a character pack folder
    static func validate(folderURL: URL) -> PackValidationResult {
        var errors: [String] = []
        var warnings: [String] = []
        var packInfo: PackInfo?

        logger.info("Validating pack at: \(folderURL.path, privacy: .public)")

        // Check folder exists
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return PackValidationResult(
                isValid: false,
                errors: ["Not a valid folder"],
                warnings: [],
                packInfo: nil
            )
        }

        // Check for character.json (single character pack)
        let singleJsonPath = folderURL.appendingPathComponent("character.json")
        if FileManager.default.fileExists(atPath: singleJsonPath.path) {
            let result = validateCharacterJSON(
                at: singleJsonPath,
                basePath: folderURL,
                isSingleCharacter: true,
                folderId: folderURL.lastPathComponent
            )
            errors.append(contentsOf: result.errors)
            warnings.append(contentsOf: result.warnings)
            packInfo = result.packInfo
        } else {
            // Multi-character pack - look for any .json files
            do {
                let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil)
                let jsonFiles = contents.filter { $0.pathExtension == "json" }

                if jsonFiles.isEmpty {
                    errors.append("No character.json or character definition files found")
                } else {
                    var allAnimationNames: Set<String> = []
                    var validCharacterCount = 0

                    for jsonFile in jsonFiles {
                        let result = validateCharacterJSON(
                            at: jsonFile,
                            basePath: folderURL,
                            isSingleCharacter: false,
                            folderId: folderURL.lastPathComponent
                        )
                        if result.errors.isEmpty {
                            validCharacterCount += 1
                            if let info = result.packInfo {
                                allAnimationNames.formUnion(info.animationNames)
                            }
                        } else {
                            errors.append(contentsOf: result.errors.map { "\(jsonFile.lastPathComponent): \($0)" })
                        }
                        warnings.append(contentsOf: result.warnings.map { "\(jsonFile.lastPathComponent): \($0)" })
                    }

                    if validCharacterCount > 0 {
                        packInfo = PackInfo(
                            id: folderURL.lastPathComponent,
                            name: folderURL.lastPathComponent.prefix(1).uppercased() + folderURL.lastPathComponent.dropFirst(),
                            isSingleCharacter: false,
                            characterCount: validCharacterCount,
                            animationNames: Array(allAnimationNames).sorted()
                        )
                    }
                }
            } catch {
                errors.append("Failed to read folder contents: \(error.localizedDescription)")
            }
        }

        let isValid = errors.isEmpty && packInfo != nil

        logger.info("Validation complete - valid: \(isValid), errors: \(errors.count), warnings: \(warnings.count)")

        return PackValidationResult(
            isValid: isValid,
            errors: errors,
            warnings: warnings,
            packInfo: packInfo
        )
    }

    // MARK: - Private

    private struct CharacterValidationResult {
        let errors: [String]
        let warnings: [String]
        let packInfo: PackInfo?
    }

    private static func validateCharacterJSON(
        at jsonURL: URL,
        basePath: URL,
        isSingleCharacter: Bool,
        folderId: String
    ) -> CharacterValidationResult {
        var errors: [String] = []
        var warnings: [String] = []

        // Try to read and decode the JSON
        guard let data = FileManager.default.contents(atPath: jsonURL.path) else {
            return CharacterValidationResult(
                errors: ["Cannot read file"],
                warnings: [],
                packInfo: nil
            )
        }

        let definition: CharacterDefinition
        do {
            definition = try JSONDecoder().decode(CharacterDefinition.self, from: data)
        } catch {
            return CharacterValidationResult(
                errors: ["Invalid JSON: \(error.localizedDescription)"],
                warnings: [],
                packInfo: nil
            )
        }

        // Validate required states are mapped
        let mappedStates = Set(definition.states.keys)
        let missingStates = Set(requiredStates).subtracting(mappedStates)
        if !missingStates.isEmpty {
            errors.append("Missing required states: \(missingStates.sorted().joined(separator: ", "))")
        }

        // Validate each mapped state points to an existing animation
        for (state, animationName) in definition.states where definition.animations[animationName] == nil {
            errors.append("State '\(state)' maps to undefined animation '\(animationName)'")
        }

        // Validate sprite files exist and are valid images
        var animationNames: [String] = []
        for (animName, animDef) in definition.animations {
            animationNames.append(animName)

            let spriteURL = basePath.appendingPathComponent(animDef.file)
            if !FileManager.default.fileExists(atPath: spriteURL.path) {
                warnings.append("Sprite file missing: \(animDef.file)")
            } else if !isValidImage(at: spriteURL) {
                warnings.append("Invalid image file: \(animDef.file)")
            }
        }

        // Create pack info
        let packInfo = PackInfo(
            id: isSingleCharacter ? folderId : definition.id,
            name: definition.name,
            isSingleCharacter: isSingleCharacter,
            characterCount: 1,
            animationNames: animationNames.sorted()
        )

        return CharacterValidationResult(
            errors: errors,
            warnings: warnings,
            packInfo: packInfo
        )
    }

    private static func isValidImage(at url: URL) -> Bool {
        guard let image = NSImage(contentsOf: url) else {
            return false
        }
        // Check it has valid size
        return image.size.width > 0 && image.size.height > 0
    }
}
