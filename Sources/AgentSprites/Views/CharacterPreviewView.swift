import SwiftUI
import AppKit

/// Animated character preview for settings
struct CharacterPreviewView: View {
    let character: SpriteCharacter
    let state: String
    let hueRotation: Double
    let size: CGFloat

    @State private var currentFrame: Int = 0

    var body: some View {
        Group {
            if let animation = character.animation(for: state),
               let image = animation.frame(at: currentFrame) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
                    .hueRotation(.degrees(hueRotation))
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: size, height: size)
            }
        }
        .onChange(of: state) { _ in
            currentFrame = 0
        }
        .onChange(of: character.id) { _ in
            currentFrame = 0
        }
        .task(id: "\(state)-\(character.id)") {
            let animation = character.animation(for: state)
            let fps = animation?.fps ?? 10
            let frameCount = animation?.frameCount ?? 1
            let interval = 1.0 / fps

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                currentFrame = (currentFrame + 1) % frameCount
            }
        }
    }
}

/// Grid of character previews for a pack
@MainActor
struct CharacterPreviewGrid: View {
    let pack: CharacterPack
    let state: String
    let previewSize: CGFloat = 64

    var body: some View {
        if pack.isSingleCharacter {
            // Show same character with different hue rotations
            hueRotationPreviews
        } else {
            // Show different characters from the pack
            characterPreviews
        }
    }

    @ViewBuilder
    private var hueRotationPreviews: some View {
        let hues: [Double] = [0, 90, 180, 270]

        if let character = CharacterManager.shared.character(forIndex: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize + 8))], spacing: 8) {
                ForEach(hues, id: \.self) { hue in
                    CharacterPreviewView(
                        character: character,
                        state: state,
                        hueRotation: hue,
                        size: previewSize
                    )
                    .background(Color.black.opacity(0.2))
                    .cornerRadius(8)
                }
            }
        }
    }

    private var rowHeight: CGFloat {
        previewSize + 4 + 14  // image + spacing + label
    }

    @ViewBuilder
    private var characterPreviews: some View {
        let characterIds = CharacterManager.shared.availableCharacters

        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize + 8))], spacing: 8) {
                ForEach(characterIds, id: \.self) { charId in
                    if let character = CharacterManager.shared.character(byId: charId) {
                        VStack(spacing: 4) {
                            CharacterPreviewView(
                                character: character,
                                state: state,
                                hueRotation: 0,
                                size: previewSize
                            )
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(8)

                            Text(character.name)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .frame(width: previewSize)
                        }
                    }
                }
            }
        }
        .frame(height: rowHeight * 2 + 8)  // 2 rows + spacing
    }
}
