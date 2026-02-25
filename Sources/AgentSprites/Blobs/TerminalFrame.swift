import SwiftUI

/// Shared retro terminal frame component
struct TerminalFrame<Content: View>: View {
    let content: Content
    @State private var scanlineOffset: CGFloat = 0

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            // Dark background
            RoundedRectangle(cornerRadius: 8)
                .fill(BlobColors.terminalBackground)

            // Scanline overlay
            ScanlineOverlay(offset: scanlineOffset)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .opacity(0.15)

            // Content
            content

            // CRT edge glow
            RoundedRectangle(cornerRadius: 8)
                .stroke(BlobColors.terminalGreen.opacity(0.3), lineWidth: 1)

            // Inner glow
            RoundedRectangle(cornerRadius: 6)
                .stroke(BlobColors.terminalGreen.opacity(0.1), lineWidth: 2)
                .padding(2)
        }
        .shadow(color: BlobColors.terminalGreen.opacity(0.2), radius: 8)
        .onAppear {
            startScanlineAnimation()
        }
    }

    private func startScanlineAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            scanlineOffset += 1
            if scanlineOffset > 4 {
                scanlineOffset = 0
            }
        }
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
