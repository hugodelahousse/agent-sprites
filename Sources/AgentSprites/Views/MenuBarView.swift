import SwiftUI
import AgentSpritesCore

struct MenuBarView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var spriteCoordinator: SpriteCoordinator
    @ObservedObject var appState: AppState
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header with settings gear
            HStack {
                Text("AgentSprites")
                    .font(.headline)
                Spacer()
                Button(
                    action: {
                        SettingsWindowController.shared.show(
                            spriteCoordinator: spriteCoordinator,
                            appState: appState,
                            updateChecker: updateChecker
                        )
                    },
                    label: {
                        Image(systemName: "gearshape")
                            .foregroundColor(.secondary)
                    }
                )
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            // Update available banner
            if updateChecker.updateState != .none {
                UpdateBannerView(updateChecker: updateChecker)
                    .padding(.horizontal, 12)
            }

            // Hook installation prompt (only shown when needed)
            if appState.showingHookPrompt {
                HookInstallPromptView(appState: appState)
                    .padding(.horizontal, 12)
                Divider()
            }

            // Show sprites toggle
            Toggle(isOn: $spriteCoordinator.isEnabled) {
                Label("Show Sprites", systemImage: "sparkles")
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 12)

            Divider()

            // Sessions list
            if viewModel.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No active sessions")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    if !appState.hooksInstalled {
                        Text("Install hooks via Settings")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(viewModel.sessions) { session in
                            SessionRowView(
                                session: session,
                                onTap: { viewModel.focusSession(session) },
                                onClose: { viewModel.closeSession(session) }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                }
                .frame(maxHeight: 300)
            }

            Divider()

            // Footer with quit action
            HStack {
                Spacer()

                Button(
                    action: { NSApplication.shared.terminate(nil) },
                    label: { Label("Quit", systemImage: "xmark.circle") }
                )
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 300)
        .task {
            updateChecker.checkOnLaunch()
        }
    }
}

// MARK: - Update Banner

struct UpdateBannerView: View {
    @ObservedObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch updateChecker.updateState {
            case .none:
                EmptyView()

            case .available(let release):
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundColor(.blue)
                    Text("v\(release.version) available")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Button {
                        updateChecker.dismissUpdate()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Button("Update & Restart") {
                        updateChecker.downloadAndInstall(release: release)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Release Notes") {
                        NSWorkspace.shared.open(release.releaseURL)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

            case .downloading(let progress):
                HStack {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.blue)
                    Text("Downloading update...")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

            case .readyToInstall:
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Ready to install")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                }
                Button("Restart Now") {
                    updateChecker.installAndRelaunch()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            case .installing:
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing...")
                        .font(.subheadline)
                        .fontWeight(.medium)
                }

            case .failed(let message):
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("Update failed")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Spacer()
                }
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                HStack {
                    Button("Retry") {
                        Task {
                            await updateChecker.checkForUpdates()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Dismiss") {
                        updateChecker.dismissUpdate()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(updateBannerColor.opacity(0.1))
        .cornerRadius(8)
    }

    private var updateBannerColor: Color {
        switch updateChecker.updateState {
        case .failed:
            return .red
        default:
            return .blue
        }
    }
}

struct HookInstallPromptView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch appState.hookPromptType {
            case .install:
                installPrompt
            case .replace(let existingPath):
                replacePrompt(existingPath: existingPath)
            case .none:
                EmptyView()
            }
        }
        .padding(10)
        .background(promptBackgroundColor.opacity(0.1))
        .cornerRadius(8)
    }

    private var promptBackgroundColor: Color {
        switch appState.hookPromptType {
        case .replace:
            return .orange
        default:
            return .blue
        }
    }

    private var installPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "link.badge.plus")
                    .foregroundColor(.blue)
                Text("Install Claude Code Hooks?")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text("AgentSprites needs hooks to receive session updates.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Install") {
                    appState.installHooks()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Later") {
                    appState.skipHookInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func replacePrompt(existingPath: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text("Different Installation Found")
                    .font(.subheadline)
                    .fontWeight(.medium)
            }

            Text(shortenPath(existingPath))
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button("Replace") {
                    appState.installHooks()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("Keep") {
                    appState.skipHookInstall()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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
