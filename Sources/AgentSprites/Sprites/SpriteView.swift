import SwiftUI
import AppKit
import AgentSpritesCore
import os.log

private let logger = Logger(subsystem: "com.agentsprites.app", category: "SpriteView")

/// SwiftUI view rendering a character sprite
struct SpriteView: View {
    let image: NSImage?
    let facingRight: Bool
    let size: CGSize
    var rotation: Double = 0  // Radians

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if let image {
                    Image(nsImage: image)
                        .interpolation(.none)  // Keep pixel art crisp
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(x: facingRight ? 1 : -1, y: 1)
                        .rotationEffect(.radians(rotation))
                } else {
                    // Don't render anything if sprite failed to load - likely a timing issue
                    Color.clear
                        .onAppear {
                            logger.warning("SpriteView rendered with nil image - sprite may still be loading")
                        }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

#Preview {
    HStack(spacing: 20) {
        SpriteView(image: CharacterManager.shared.character(forIndex: 0)?.animation(for: "idle")?.frame(at: 0), facingRight: true, size: CGSize(width: 64, height: 64))
        SpriteView(image: CharacterManager.shared.character(forIndex: 0)?.animation(for: "working")?.frame(at: 0), facingRight: false, size: CGSize(width: 64, height: 64))
        SpriteView(image: nil, facingRight: true, size: CGSize(width: 64, height: 64))
    }
    .padding()
    .background(Color.black)
}
