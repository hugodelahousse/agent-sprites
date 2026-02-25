import SwiftUI
import AgentSpritesCore

struct SessionRowView: View {
    let session: SessionState
    var onTap: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            // Status indicator
            StatusIndicator(status: session.status)

            // Session info
            VStack(alignment: .leading, spacing: 2) {
                // Show summary if available, otherwise folder name
                Text(session.summary ?? session.displayName)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(session.status.displayName)
                        .font(.caption)
                        .foregroundColor(statusColor)

                    // Show git branch if available
                    if let branch = session.gitBranch, !branch.isEmpty {
                        Text("•")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            // Time since last update
            Text(timeAgo(from: session.lastUpdated))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onTap?()
        }
        .help(debugTooltip)
    }

    private var debugTooltip: String {
        var lines: [String] = []
        if let summary = session.summary {
            lines.append("Summary: \(summary)")
        }
        lines.append("Directory: \(session.workingDirectory)")
        if let branch = session.gitBranch, !branch.isEmpty {
            lines.append("Branch: \(branch)")
        }
        lines.append("Session: \(session.id)")
        lines.append("TTY: \(session.tty ?? "nil")")
        lines.append("BundleID: \(session.bundleId ?? "nil")")
        return lines.joined(separator: "\n")
    }

    private var statusColor: Color {
        switch session.status {
        case .idle:
            return .secondary
        case .working:
            return .blue
        case .waitingForInput:
            return .yellow
        case .waitingForPermission:
            return .red
        case .error:
            return .red
        case .done:
            return .green
        }
    }

    private func timeAgo(from date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "now"
        } else if interval < 3600 {
            let minutes = Int(interval / 60)
            return "\(minutes)m"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h"
        } else {
            let days = Int(interval / 86400)
            return "\(days)d"
        }
    }
}

struct StatusIndicator: View {
    let status: SessionStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor)
                .frame(width: 32, height: 32)

            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(foregroundColor)
        }
    }

    private var iconName: String {
        switch status {
        case .idle:
            return "moon.zzz"
        case .working:
            return "keyboard"
        case .waitingForInput:
            return "questionmark.bubble"
        case .waitingForPermission:
            return "lock"
        case .error:
            return "exclamationmark.triangle"
        case .done:
            return "checkmark"
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .idle:
            return Color.gray.opacity(0.2)
        case .working:
            return Color.blue.opacity(0.2)
        case .waitingForInput:
            return Color.yellow.opacity(0.2)
        case .waitingForPermission:
            return Color.red.opacity(0.2)
        case .error:
            return Color.red.opacity(0.2)
        case .done:
            return Color.green.opacity(0.2)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .idle:
            return .gray
        case .working:
            return .blue
        case .waitingForInput:
            return .orange
        case .waitingForPermission:
            return .red
        case .error:
            return .red
        case .done:
            return .green
        }
    }
}
