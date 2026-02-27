import SwiftUI
import AgentSpritesCore

struct SessionRowView: View {
    let session: SessionState
    var onTap: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        // Resolve character data here (body is @MainActor via View protocol)
        let character: SpriteCharacter? = if CharacterManager.shared.usesRandomCharacter {
            CharacterManager.shared.character(forPath: session.workingDirectory)
        } else {
            CharacterManager.shared.character(forIndex: 0)
        }
        let hueRotation: Double = if CharacterManager.shared.usesHueRotation {
            Self.hueForPath(session.workingDirectory, seed: CharacterManager.shared.mappingSeed)
        } else {
            0
        }

        HStack(spacing: 12) {
            // Animated character indicator
            SessionCharacterIndicator(
                character: character,
                hueRotation: hueRotation,
                status: session.status
            )

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

            // Close button on hover, time ago otherwise
            if isHovering {
                Button(action: { onClose?() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close session")
            } else {
                Text(timeAgo(from: session.lastUpdated))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.05))
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovering = hovering
        }
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

    private static func hueForPath(_ path: String, seed: UInt64) -> Double {
        var hash: UInt64 = 5381 ^ seed
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return Double(hash % 360)
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

/// Animated character indicator for session rows
struct SessionCharacterIndicator: View {
    let character: SpriteCharacter?
    let hueRotation: Double
    let status: SessionStatus

    @State private var currentFrame: Int = 0

    private var animationState: String {
        switch status {
        case .idle:
            return "idle"
        case .working:
            return "working"
        case .waitingForInput:
            return "waitingForInput"
        case .waitingForPermission:
            return "waitingForPermission"
        case .error:
            return "error"
        case .done:
            return "done"
        }
    }

    var body: some View {
        Group {
            if let character,
               let animation = character.animation(for: animationState),
               let image = animation.frame(at: currentFrame) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .hueRotation(.degrees(hueRotation))
            } else {
                // Fallback to colored circle if no character
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)
            }
        }
        .onChange(of: status) { _ in
            currentFrame = 0
        }
        .task(id: "\(animationState)-\(character?.id ?? "")") {
            guard let character else { return }
            let animation = character.animation(for: animationState)
            let fps = animation?.fps ?? 10
            let frameCount = animation?.frameCount ?? 1
            let interval = 1.0 / fps

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                currentFrame = (currentFrame + 1) % frameCount
            }
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle:
            return .gray
        case .working:
            return .blue
        case .waitingForInput:
            return .yellow
        case .waitingForPermission, .error:
            return .red
        case .done:
            return .green
        }
    }
}
