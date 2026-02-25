import SwiftUI
import AppKit
import AgentSpritesCore

/// SwiftUI view rendering a slime sprite
struct BlobView: View {
    let image: NSImage?
    let facingRight: Bool
    let size: CGSize

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image)
                    .interpolation(.none)  // Keep pixel art crisp
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(x: facingRight ? 1 : -1, y: 1)
            } else {
                // Fallback circle if sprites not loaded
                Circle()
                    .fill(Color.green.opacity(0.8))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    HStack(spacing: 20) {
        BlobView(image: SlimeSpriteManager.shared.idle?.frame(at: 0), facingRight: true, size: CGSize(width: 64, height: 64))
        BlobView(image: SlimeSpriteManager.shared.walk?.frame(at: 0), facingRight: false, size: CGSize(width: 64, height: 64))
        BlobView(image: nil, facingRight: true, size: CGSize(width: 64, height: 64))
    }
    .padding()
    .background(Color.black)
}
