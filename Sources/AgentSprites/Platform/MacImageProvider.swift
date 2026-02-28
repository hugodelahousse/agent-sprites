import AgentSpritesCore
import AppKit

/// Wraps NSImage to conform to PlatformImage
final class MacImage: PlatformImage, @unchecked Sendable {
    let nsImage: NSImage

    var size: CGSize { nsImage.size }

    init(_ nsImage: NSImage) {
        self.nsImage = nsImage
    }

    /// Access the underlying CGImage for cropping operations
    var cgImage: CGImage? {
        nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// macOS image provider using NSImage/CGImage
final class MacImageProvider: ImageProvider, Sendable {
    typealias Image = MacImage

    func loadImage(fromPath path: String) -> MacImage? {
        guard let nsImage = NSImage(contentsOfFile: path) else { return nil }
        return MacImage(nsImage)
    }

    func cropImage(_ image: MacImage, to rect: CGRect) -> MacImage? {
        guard let cgImage = image.cgImage,
              let cropped = cgImage.cropping(to: rect) else {
            return nil
        }
        return MacImage(NSImage(cgImage: cropped, size: rect.size))
    }

    func cropImage(_ image: MacImage, to rect: CGRect, displaySize: CGSize) -> MacImage? {
        guard let cgImage = image.cgImage,
              let cropped = cgImage.cropping(to: rect) else {
            return nil
        }
        return MacImage(NSImage(cgImage: cropped, size: displaySize))
    }
}
