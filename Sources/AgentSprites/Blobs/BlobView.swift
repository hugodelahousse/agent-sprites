import SwiftUI
import AppKit
import AgentSpritesCore

/// SwiftUI view rendering a slime sprite
struct BlobView: View {
    let image: NSImage?
    let facingRight: Bool
    let size: CGSize
    var rotation: Double = 0  // Radians

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .interpolation(.none)  // Keep pixel art crisp
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: facingRight ? 1 : -1, y: 1)
                    .rotationEffect(.radians(rotation))
            } else {
                // Fallback circle if sprites not loaded
                Circle()
                    .fill(Color.green.opacity(0.8))
                    .rotationEffect(.radians(rotation))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    HStack(spacing: 20) {
        BlobView(image: CharacterManager.shared.character(forIndex: 0)?.animation(for: "idle")?.frame(at: 0), facingRight: true, size: CGSize(width: 64, height: 64))
        BlobView(image: CharacterManager.shared.character(forIndex: 0)?.animation(for: "working")?.frame(at: 0), facingRight: false, size: CGSize(width: 64, height: 64))
        BlobView(image: nil, facingRight: true, size: CGSize(width: 64, height: 64))
    }
    .padding()
    .background(Color.black)
}
