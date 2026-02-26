import SwiftUI

/// Available animation states for preview
enum PreviewState: String, CaseIterable, Identifiable {
    case idle = "idle"
    case working = "working"
    case moving = "moving"
    case waitingForInput = "waitingForInput"
    case waitingForPermission = "waitingForPermission"
    case error = "error"
    case done = "done"
    case dragging = "dragging"
    case falling = "falling"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .idle: return "Idle"
        case .working: return "Working"
        case .moving: return "Moving"
        case .waitingForInput: return "Waiting"
        case .waitingForPermission: return "Permission"
        case .error: return "Error"
        case .done: return "Done"
        case .dragging: return "Dragging"
        case .falling: return "Falling"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var blobCoordinator: BlobCoordinator
    @State private var previewState: PreviewState = .idle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Character Settings")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // Pack selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Character Pack")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ForEach(blobCoordinator.availablePacks) { pack in
                            PackRowView(
                                pack: pack,
                                isSelected: blobCoordinator.selectedPackId == pack.id
                            ) {
                                blobCoordinator.selectedPackId = pack.id
                            }
                        }
                    }

                    Divider()

                    // State picker
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview State")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(PreviewState.allCases) { state in
                                    StateChip(
                                        state: state,
                                        isSelected: previewState == state
                                    ) {
                                        previewState = state
                                    }
                                }
                            }
                        }
                    }

                    Divider()

                    // Character previews
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Preview")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if let selectedPack = blobCoordinator.availablePacks.first(where: { $0.id == blobCoordinator.selectedPackId }) {
                            CharacterPreviewGrid(
                                pack: selectedPack,
                                state: previewState.rawValue
                            )
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 400, height: 500)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct PackRowView: View {
    let pack: CharacterPack
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name)
                        .fontWeight(isSelected ? .medium : .regular)

                    Text(pack.isSingleCharacter ? "Hue rotation mode" : "\(pack.characterCount) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

struct StateChip: View {
    let state: PreviewState
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            Text(state.displayName)
                .font(.caption)
                .fontWeight(isSelected ? .medium : .regular)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.2))
                .foregroundColor(isSelected ? .white : .primary)
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    private init() {}

    func show(blobCoordinator: BlobCoordinator) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(blobCoordinator: blobCoordinator)
        let hostingController = NSHostingController(rootView: settingsView)
        self.hostingController = hostingController

        let window = NSWindow(contentViewController: hostingController)
        window.title = "AgentSprites Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.level = .floating
        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
        hostingController = nil
    }
}
