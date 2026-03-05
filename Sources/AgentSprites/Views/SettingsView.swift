import ApplicationServices
import SwiftUI

// MARK: - Settings Tabs

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case characters = "Characters"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .characters: return "person.crop.rectangle.stack"
        }
    }
}

// MARK: - Main Settings View

struct SettingsView: View {
    @ObservedObject var spriteCoordinator: SpriteCoordinator
    @ObservedObject var appState: AppState
    @State private var selectedTab: SettingsTab? = .general

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            ZStack(alignment: .topLeading) {
                VisualEffectView(material: .sidebar, blendingMode: .behindWindow)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsTab.allCases) { tab in
                        SidebarRow(
                            title: tab.rawValue,
                            icon: tab.icon,
                            isSelected: selectedTab == tab
                        ) {
                            selectedTab = tab
                        }
                    }
                }
                .padding(.top, 52) // Space for traffic lights
                .padding(.horizontal, 12)
            }
            .frame(width: 200)

            // Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)

            // Detail
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedTab {
        case .general:
            GeneralSettingsView(appState: appState, spriteCoordinator: spriteCoordinator)
        case .characters:
            CharacterSettingsView(spriteCoordinator: spriteCoordinator)
        case .none:
            Text("Select a category")
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var spriteCoordinator: SpriteCoordinator
    @State private var accessibilityGranted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                HStack {
                    Label {
                        Text(appState.hooksInstalled ? "Hooks are installed" : "Hooks not installed")
                    } icon: {
                        Circle()
                            .fill(appState.hooksInstalled ? Color.green : Color.orange)
                            .frame(width: 10, height: 10)
                    }
                    Spacer()
                    Button(appState.hooksInstalled ? "Reinstall" : "Install") {
                        appState.installHooks()
                    }
                }

                if let cliPath = HookInstaller.bundledCLIPath {
                    LabeledContent("CLI Path") {
                        Text(shortenPath(cliPath))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            } header: {
                Text("Claude Code Hooks")
            }

            Section {
                if accessibilityGranted {
                    Label {
                        Text("Accessibility enabled")
                    } icon: {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 10, height: 10)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .font(.system(size: 14))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Accessibility not enabled")
                                .font(.system(size: 12, weight: .medium))
                            Text("Sprites react to window changes with a delay. Grant accessibility access for instant response.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Grant Access") {
                            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
                            _ = AXIsProcessTrustedWithOptions(options)
                        }
                    }
                }
            } header: {
                Text("Accessibility")
            }

            #if DEBUG
            Section {
                Toggle("Show Ledge Overlay", isOn: $spriteCoordinator.debugLedgesEnabled)
            } header: {
                Text("Debug")
            } footer: {
                Text("Visualize detected window ledges for sprite positioning")
            }
            #endif
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 20)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let granted = AXIsProcessTrusted()
            if granted != accessibilityGranted {
                accessibilityGranted = granted
                if granted {
                    WindowObserver.shared.startObserving()
                }
            }
        }
    }

    private func shortenPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Character Settings

struct CharacterSettingsView: View {
    @ObservedObject var spriteCoordinator: SpriteCoordinator
    @State private var previewState: PreviewState = .idle
    @State private var showImportSheet = false

    var body: some View {
        Form {
            Section {
                ForEach(spriteCoordinator.availablePacks) { pack in
                    PackRowView(
                        pack: pack,
                        isSelected: spriteCoordinator.selectedPackId == pack.id
                    ) {
                        spriteCoordinator.selectedPackId = pack.id
                    }
                }

                Button {
                    showImportSheet = true
                } label: {
                    Label("Import Pack...", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
            } header: {
                Text("Character Pack")
            }

            Section {
                HStack {
                    Text("Each session gets a unique color variant")
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Randomize") {
                        spriteCoordinator.randomizeMappings()
                    }
                }
            } header: {
                Text("Colors")
            }

            Section {
                VStack(alignment: .leading, spacing: 12) {
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

                    if let selectedPack = spriteCoordinator.availablePacks.first(where: { $0.id == spriteCoordinator.selectedPackId }) {
                        CharacterPreviewGrid(
                            characters: selectedPack.isSingleCharacter
                                ? [CharacterManager.shared.character(forIndex: 0)].compactMap { $0 }
                                : CharacterManager.shared.availableCharacters.compactMap { CharacterManager.shared.character(byId: $0) },
                            isSingleCharacter: selectedPack.isSingleCharacter,
                            state: previewState.rawValue
                        )
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Preview")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .padding(.top, 20)
        .sheet(isPresented: $showImportSheet) {
            ImportPackView { packId in
                CharacterManager.shared.selectNewlyImportedPack(packId)
                spriteCoordinator.selectedPackId = packId
            }
        }
    }
}

// MARK: - Preview State

enum PreviewState: String, CaseIterable, Identifiable {
    case idle, working, moving, waitingForInput, waitingForPermission, error, done, dragging, falling

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

// MARK: - Pack Row

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
                        .foregroundColor(.primary)

                    Text(pack.isSingleCharacter ? "Hue rotation mode" : "\(pack.characterCount) characters")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - State Chip

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

// MARK: - Sidebar Row

struct SidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
            .foregroundColor(isSelected ? .accentColor : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Visual Effect View

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() {
        super.init()
    }

    func show(spriteCoordinator: SpriteCoordinator, appState: AppState) {
        if let existingWindow = window, existingWindow.isVisible {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(spriteCoordinator: spriteCoordinator, appState: appState)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = ""
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.setContentSize(NSSize(width: 650, height: 500))
        window.minSize = NSSize(width: 500, height: 400)

        window.center()
        window.makeKeyAndOrderFront(nil)

        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
