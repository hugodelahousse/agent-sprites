import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Import State

enum ImportState: Equatable {
    case selectFile
    case extracting
    case validating
    case preview(PackInfo)
    case importing
    case success(packId: String)
    case error(String)

    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.selectFile, .selectFile),
             (.extracting, .extracting),
             (.validating, .validating),
             (.importing, .importing):
            return true
        case let (.preview(a), .preview(b)):
            return a.id == b.id
        case let (.success(a), .success(b)):
            return a == b
        case let (.error(a), .error(b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - Conflict Resolution

enum ConflictResolution {
    case replace
    case keepBoth
    case cancel
}

// MARK: - Import Pack View

struct ImportPackView: View {
    @Environment(\.dismiss) private var dismiss
    let onImportComplete: (String) -> Void

    @State private var importState: ImportState = .selectFile
    @State private var validationResult: PackValidationResult?
    @State private var sourceURL: URL?
    @State private var packFolderURL: URL?
    @State private var tempDirectoryURL: URL?
    @State private var showConflictAlert = false
    @State private var conflictPackId: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Import Character Pack")
                    .font(.headline)
                Spacer()
                Button {
                    cleanup()
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // Content based on state
            Group {
                switch importState {
                case .selectFile:
                    selectFileView
                case .extracting:
                    progressView(title: "Extracting...", subtitle: "Unpacking zip archive")
                case .validating:
                    progressView(title: "Validating...", subtitle: "Checking pack structure")
                case .preview(let info):
                    previewView(info: info)
                case .importing:
                    progressView(title: "Installing...", subtitle: "Copying files")
                case .success(let packId):
                    successView(packId: packId)
                case .error(let message):
                    errorView(message: message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 500, height: 400)
        .alert("Pack Already Exists", isPresented: $showConflictAlert) {
            Button("Replace") {
                handleConflictResolution(.replace)
            }
            Button("Keep Both") {
                handleConflictResolution(.keepBoth)
            }
            Button("Cancel", role: .cancel) {
                handleConflictResolution(.cancel)
            }
        } message: {
            Text("A pack named '\(conflictPackId ?? "")' already exists. What would you like to do?")
        }
    }

    // MARK: - Select File View

    private var selectFileView: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("Choose a character pack folder or .zip file to import")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Choose Pack...") {
                selectFile()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Progress View

    private func progressView(title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Preview View

    private func previewView(info: PackInfo) -> some View {
        VStack(spacing: 16) {
            // Pack info header
            VStack(spacing: 4) {
                Text(info.name)
                    .font(.title2)
                    .fontWeight(.semibold)

                Text(info.isSingleCharacter ? "Single character (hue rotation)" : "\(info.characterCount) characters")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Validation status
            if let result = validationResult {
                ValidationStatusView(result: result)
            }

            // Animation preview
            if let folderURL = packFolderURL {
                PackPreviewGrid(
                    folderURL: folderURL,
                    isSingleCharacter: info.isSingleCharacter
                )
                .frame(height: 140)
            }

            Spacer()

            // Action buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    cleanup()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Install") {
                    installPack(info: info)
                }
                .buttonStyle(.borderedProminent)
                .disabled(validationResult?.isValid != true)
            }
            .padding(.bottom, 16)
        }
        .padding()
    }

    // MARK: - Success View

    private func successView(packId: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.green)

            Text("Pack Installed!")
                .font(.headline)

            Text("'\(packId)' is now available in your character packs.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Button("Done") {
                cleanup()
                onImportComplete(packId)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: - Error View

    private func errorView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Import Failed")
                .font(.headline)

            Text(message)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 12) {
                Button("Cancel") {
                    cleanup()
                    dismiss()
                }
                .buttonStyle(.bordered)

                Button("Try Again") {
                    importState = .selectFile
                    cleanup()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - File Selection

    private func selectFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.folder, .zip]
        panel.message = "Select a character pack folder or .zip file"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        sourceURL = url
        processSelectedFile(url)
    }

    private func processSelectedFile(_ url: URL) {
        Task {
            do {
                // Check if it's a zip file
                if url.pathExtension.lowercased() == "zip" {
                    importState = .extracting
                    let extractedURL = try CharacterPackImporter.extractZip(at: url)
                    tempDirectoryURL = extractedURL
                    packFolderURL = extractedURL
                } else {
                    packFolderURL = url
                }

                // Validate the pack
                importState = .validating
                guard let folderURL = packFolderURL else {
                    throw CharacterPackImportError.noPackFound
                }

                let result = CharacterPackValidator.validate(folderURL: folderURL)
                validationResult = result

                if let info = result.packInfo {
                    importState = .preview(info)
                } else {
                    importState = .error("Invalid pack structure: " + result.errors.joined(separator: ", "))
                }
            } catch {
                importState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Installation

    private func installPack(info: PackInfo) {
        // Check for existing pack
        if CharacterPackImporter.packExists(id: info.id) {
            conflictPackId = info.id
            showConflictAlert = true
            return
        }

        performInstall(packId: info.id)
    }

    private func handleConflictResolution(_ resolution: ConflictResolution) {
        guard let packId = conflictPackId else { return }

        switch resolution {
        case .replace:
            do {
                try CharacterPackImporter.removeExistingPack(id: packId)
                performInstall(packId: packId)
            } catch {
                importState = .error("Failed to remove existing pack: \(error.localizedDescription)")
            }
        case .keepBoth:
            let newId = CharacterPackImporter.generateUniquePackId(base: packId)
            performInstall(packId: newId)
        case .cancel:
            break
        }
    }

    private func performInstall(packId: String) {
        guard let folderURL = packFolderURL else { return }

        importState = .importing

        Task {
            do {
                let installedId = try await CharacterPackImporter.install(from: folderURL, as: packId)
                importState = .success(packId: installedId)
            } catch {
                importState = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Cleanup

    private func cleanup() {
        if let tempURL = tempDirectoryURL {
            CharacterPackImporter.cleanupTempDirectory(tempURL)
        }
        tempDirectoryURL = nil
    }
}

// MARK: - Validation Status View

private struct ValidationStatusView: View {
    let result: PackValidationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !result.errors.isEmpty {
                ForEach(result.errors, id: \.self) { error in
                    Label(error, systemImage: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            if !result.warnings.isEmpty {
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if result.isValid && result.warnings.isEmpty {
                Label("All checks passed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}

// MARK: - Pack Preview Grid

private struct PackPreviewGrid: View {
    let folderURL: URL
    let isSingleCharacter: Bool

    @State private var characters: [SpriteCharacter] = []
    @State private var selectedState: String = "idle"

    private let allStates = [
        "idle", "working", "moving", "waitingForInput",
        "waitingForPermission", "error", "done", "dragging", "falling"
    ]

    var body: some View {
        VStack(spacing: 8) {
            // State selector
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(allStates, id: \.self) { state in
                        Button {
                            selectedState = state
                        } label: {
                            Text(displayName(for: state))
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedState == state ? Color.accentColor : Color.gray.opacity(0.2))
                                .foregroundColor(selectedState == state ? .white : .primary)
                                .cornerRadius(6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }

            // Character previews
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    if isSingleCharacter {
                        // Show hue rotation variants
                        ForEach([0.0, 90.0, 180.0, 270.0], id: \.self) { hue in
                            if let character = characters.first {
                                ImportPreviewCell(character: character, hueRotation: hue, state: selectedState)
                            }
                        }
                    } else {
                        // Show each character
                        ForEach(characters, id: \.id) { character in
                            ImportPreviewCell(character: character, hueRotation: 0, state: selectedState)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        .task {
            loadCharacters()
        }
    }

    private func displayName(for state: String) -> String {
        switch state {
        case "waitingForInput": return "input"
        case "waitingForPermission": return "permission"
        default: return state
        }
    }

    private func loadCharacters() {
        var loaded: [SpriteCharacter] = []

        // Check for single character pack
        let singleJsonPath = folderURL.appendingPathComponent("character.json")
        if let data = FileManager.default.contents(atPath: singleJsonPath.path),
           let definition = try? JSONDecoder().decode(CharacterDefinition.self, from: data) {
            loaded.append(SpriteCharacter(definition: definition, basePath: folderURL.path))
        } else {
            // Multi-character pack
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: folderURL.path) {
                for item in contents where item.hasSuffix(".json") {
                    let jsonPath = folderURL.appendingPathComponent(item).path
                    if let data = FileManager.default.contents(atPath: jsonPath),
                       let definition = try? JSONDecoder().decode(CharacterDefinition.self, from: data) {
                        loaded.append(SpriteCharacter(definition: definition, basePath: folderURL.path))
                    }
                }
            }
        }

        characters = loaded.sorted { $0.id < $1.id }
    }
}

// MARK: - Import Preview Cell

private struct ImportPreviewCell: View {
    let character: SpriteCharacter
    let hueRotation: Double
    let state: String

    @State private var currentFrame: Int = 0

    private let previewSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let animation = character.animation(for: state),
                   let image = animation.frame(at: currentFrame) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: previewSize, height: previewSize)
                        .hueRotation(.degrees(hueRotation))
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: previewSize, height: previewSize)
                }
            }
            .background(Color.black.opacity(0.2))
            .cornerRadius(8)

            Text(hueRotation > 0 ? "Variant \(Int(hueRotation / 90) + 1)" : character.name)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: previewSize)
        }
        .onChange(of: state) { _ in
            currentFrame = 0
        }
        .task(id: state) {
            let animation = character.animation(for: state)
            let fps = animation?.fps ?? 10
            let frameCount = animation?.frameCount ?? 1
            let interval = 1.0 / fps

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                currentFrame = (currentFrame + 1) % frameCount
            }
        }
    }
}
