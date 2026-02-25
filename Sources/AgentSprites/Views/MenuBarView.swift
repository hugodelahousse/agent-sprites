import SwiftUI
import AgentSpritesCore

struct MenuBarView: View {
    @ObservedObject var viewModel: SessionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack {
                Text("AgentSprites")
                    .font(.headline)
                Spacer()
                ConnectionStatusView(isConnected: viewModel.isConnected)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

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

            // Footer with actions
            HStack {
                Button(action: { viewModel.fetchSessions() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Spacer()

                Button(action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 320)
    }
}

struct ConnectionStatusView: View {
    let isConnected: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isConnected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(isConnected ? "Connected" : "Disconnected")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
