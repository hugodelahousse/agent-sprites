import SwiftUI

/// Shared retro terminal frame component
struct TerminalFrame<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Dark background
            RoundedRectangle(cornerRadius: 8)
                .fill(SpriteColors.terminalBackground)

            // Static scanline overlay (no animation to save CPU)
            ScanlineOverlay(offset: 0)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.15)

            // Content
            content

            // CRT edge glow
            RoundedRectangle(cornerRadius: 8)
                .stroke(SpriteColors.terminalGreen.opacity(0.3), lineWidth: 1)

            // Inner glow
            RoundedRectangle(cornerRadius: 6)
                .stroke(SpriteColors.terminalGreen.opacity(0.1), lineWidth: 2)
                .padding(2)
        }
        .shadow(color: SpriteColors.terminalGreen.opacity(0.2), radius: 8)
    }
}

/// Animated scanline overlay effect
struct ScanlineOverlay: View {
    let offset: CGFloat

    var body: some View {
        Canvas { context, size in
            let lineSpacing: CGFloat = 4
            var y = offset

            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
                context.fill(Path(rect), with: .color(.black))
                y += lineSpacing
            }
        }
    }
}
