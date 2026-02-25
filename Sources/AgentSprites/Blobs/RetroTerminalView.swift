import SwiftUI
import AgentSpritesCore

/// Retro CRT-style terminal view for attention messages
struct RetroTerminalView: View {
    let sessionName: String
    let message: String
    let status: SessionStatus
    let onFocusTerminal: () -> Void
    let onDismiss: () -> Void

    @State private var cursorVisible = true

    var body: some View {
        TerminalFrame {
            VStack(alignment: .leading, spacing: 6) {
                // Title bar with folder name and buttons
                HStack(spacing: 8) {
                    Text(sessionName.uppercased())
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(BlobColors.terminalGreen)
                        .lineLimit(1)

                    Spacer()

                    // Focus button (small icon)
                    Button(action: onFocusTerminal) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 11))
                            .foregroundColor(BlobColors.terminalGreen)
                    }
                    .buttonStyle(.plain)

                    // Close button
                    Button(action: onDismiss) {
                        Text("X")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(BlobColors.terminalGreen)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(BlobColors.terminalGreen.opacity(0.5), lineWidth: 1)
                    )
                }

                Divider()
                    .background(BlobColors.terminalDimGreen)

                // Status indicator
                HStack(spacing: 6) {
                    Circle()
                        .fill(BlobColors.color(for: status))
                        .frame(width: 8, height: 8)

                    Text(status.displayName.uppercased())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(BlobColors.terminalDimGreen)
                }

                // Message with blinking cursor
                HStack(spacing: 0) {
                    Text("> ")
                        .foregroundColor(BlobColors.terminalDimGreen)

                    Text(message)
                        .foregroundColor(BlobColors.terminalGreen)

                    Text("_")
                        .foregroundColor(BlobColors.terminalGreen)
                        .opacity(cursorVisible ? 1 : 0)
                }
                .font(.system(size: 11, weight: .regular, design: .monospaced))

                Spacer()
            }
            .padding(10)
        }
        .frame(width: 200, height: 100)
        .onAppear {
            startCursorBlink()
        }
    }

    private func startCursorBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            cursorVisible.toggle()
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        RetroTerminalView(
            sessionName: "agent-sprites",
            message: "Waiting for your input...",
            status: .waitingForInput,
            onFocusTerminal: {},
            onDismiss: {}
        )

        RetroTerminalView(
            sessionName: "my-project",
            message: "Permission required",
            status: .waitingForPermission,
            onFocusTerminal: {},
            onDismiss: {}
        )
    }
    .padding()
    .background(Color.gray.opacity(0.3))
}
