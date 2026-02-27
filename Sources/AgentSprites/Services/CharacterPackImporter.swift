import AgentSpritesCore
import Foundation
import os

// MARK: - Import Errors

enum CharacterPackImportError: LocalizedError {
    case zipExtractionFailed(String)
    case noPackFound
    case installFailed(String)
    case packAlreadyExists(String)

    var errorDescription: String? {
        switch self {
        case .zipExtractionFailed(let reason):
            return "Failed to extract zip: \(reason)"
        case .noPackFound:
            return "No valid character pack found in archive"
        case .installFailed(let reason):
            return "Failed to install pack: \(reason)"
        case .packAlreadyExists(let packId):
            return "A pack named '\(packId)' already exists"
        }
    }
}

// MARK: - Importer

enum CharacterPackImporter {
    private static let logger = Logger(subsystem: "com.agentsprites.app", category: "PackImporter")

    /// Extract zip to temp directory, returns URL to extracted folder
    static func extractZip(at zipURL: URL) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentsprites-import-\(UUID().uuidString)")

        logger.info("Extracting zip to: \(tempDir.path, privacy: .public)")

        // Create temp directory
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Use system unzip command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-q", zipURL.path, "-d", tempDir.path]

        let errorPipe = Pipe()
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errorMessage = String(data: errorData, encoding: .utf8) ?? "Unknown error"
            cleanupTempDirectory(tempDir)
            throw CharacterPackImportError.zipExtractionFailed(errorMessage)
        }

        // Handle nested folder case: if zip contains single folder, use that as pack root
        let extractedContents = try FileManager.default.contentsOfDirectory(
            at: tempDir,
            includingPropertiesForKeys: [.isDirectoryKey]
        )

        // Filter out hidden files like __MACOSX
        let visibleContents = extractedContents.filter { !$0.lastPathComponent.hasPrefix(".") && !$0.lastPathComponent.hasPrefix("__") }

        if visibleContents.count == 1,
           let singleItem = visibleContents.first {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: singleItem.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                logger.info("Found nested folder in zip: \(singleItem.lastPathComponent, privacy: .public)")
                return singleItem
            }
        }

        // Otherwise return the temp directory itself
        return tempDir
    }

    /// Install pack from folder (or extracted zip) to Application Support
    static func install(from sourceURL: URL, as packId: String? = nil) async throws -> String {
        let folderId = packId ?? sourceURL.lastPathComponent
        let destinationURL = AgentSpritesConstants.charactersDirectory.appendingPathComponent(folderId)

        logger.info("Installing pack '\(folderId, privacy: .public)' to \(destinationURL.path, privacy: .public)")

        // Ensure characters directory exists
        try FileManager.default.createDirectory(
            at: AgentSpritesConstants.charactersDirectory,
            withIntermediateDirectories: true
        )

        // Copy the pack folder
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw CharacterPackImportError.installFailed(error.localizedDescription)
        }

        logger.info("Pack installed successfully: \(folderId, privacy: .public)")
        return folderId
    }

    /// Check if pack already exists
    static func packExists(id: String) -> Bool {
        let packURL = AgentSpritesConstants.charactersDirectory.appendingPathComponent(id)
        return FileManager.default.fileExists(atPath: packURL.path)
    }

    /// Remove existing pack (for replacement)
    static func removeExistingPack(id: String) throws {
        let packURL = AgentSpritesConstants.charactersDirectory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: packURL.path) {
            logger.info("Removing existing pack: \(id, privacy: .public)")
            try FileManager.default.removeItem(at: packURL)
        }
    }

    /// Clean up temp extraction directory
    static func cleanupTempDirectory(_ url: URL) {
        // Only clean up if it's in the temp directory
        guard url.path.contains("agentsprites-import-") else {
            logger.warning("Refusing to clean up non-temp directory: \(url.path, privacy: .public)")
            return
        }

        // Find the root temp directory (agentsprites-import-UUID)
        var cleanupURL = url
        while !cleanupURL.lastPathComponent.hasPrefix("agentsprites-import-") {
            cleanupURL = cleanupURL.deletingLastPathComponent()
            if cleanupURL.path == "/" {
                logger.warning("Could not find temp directory root for: \(url.path, privacy: .public)")
                return
            }
        }

        logger.info("Cleaning up temp directory: \(cleanupURL.path, privacy: .public)")
        try? FileManager.default.removeItem(at: cleanupURL)
    }

    /// Generate a unique pack ID by appending a number if needed
    static func generateUniquePackId(base: String) -> String {
        var candidate = base
        var counter = 2

        while packExists(id: candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }

        return candidate
    }
}
