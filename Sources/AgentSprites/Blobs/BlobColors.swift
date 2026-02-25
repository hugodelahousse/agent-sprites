import SwiftUI
import AgentSpritesCore

/// Color configuration for blob sprites based on session state
struct BlobColors {
    /// Returns the primary color for a blob based on session status
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .idle:
            return Color.orange.opacity(0.6)
        case .working:
            return Color.orange
        case .waitingForInput:
            return Color.yellow
        case .waitingForPermission:
            return Color.red
        case .error:
            return Color.red
        case .done:
            return Color.green
        }
    }

    /// Returns whether the state requires attention (shows message window)
    static func needsAttention(for status: SessionStatus) -> Bool {
        switch status {
        case .waitingForInput, .waitingForPermission:
            return true
        default:
            return false
        }
    }

    /// Returns the glow/highlight color for a blob
    static func glowColor(for status: SessionStatus) -> Color {
        switch status {
        case .idle:
            return Color.orange.opacity(0.3)
        case .working:
            return Color.orange.opacity(0.5)
        case .waitingForInput:
            return Color.yellow.opacity(0.6)
        case .waitingForPermission, .error:
            return Color.red.opacity(0.6)
        case .done:
            return Color.green.opacity(0.5)
        }
    }

    /// Retro terminal green phosphor color
    static let terminalGreen = Color(red: 0.2, green: 1.0, blue: 0.2)

    /// Retro terminal background
    static let terminalBackground = Color(red: 0.05, green: 0.08, blue: 0.05)

    /// Retro terminal dim green for secondary text
    static let terminalDimGreen = Color(red: 0.15, green: 0.6, blue: 0.15)
}
