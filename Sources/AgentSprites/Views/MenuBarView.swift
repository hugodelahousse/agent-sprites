import SwiftUI
import AgentSpritesCore

struct MenuBarView: View {
    @ObservedObject var viewModel: SessionViewModel
    @ObservedObject var blobCoordinator: BlobCoordinator
    @ObservedObject var appState: AppState

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
                            blobCoordinator: blobCoordinator,
                            appState: appState
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

            // Hook installation prompt (only shown when needed)
            if appState.showingHookPrompt {
                HookInstallPromptView(appState: appState)
                    .padding(.horizontal, 12)
                Divider()
            }

            // Show sprites toggle
            Toggle(isOn: $blobCoordinator.isEnabled) {
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
                            SessionRowView(session: session) {
                                viewModel.focusSession(session)
                            }
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
