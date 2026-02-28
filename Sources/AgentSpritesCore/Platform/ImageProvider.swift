import Foundation

/// Type-erased wrapper for a platform-native image.
/// macOS uses NSImage; Windows will use a GDI+/Direct2D image handle.
public protocol PlatformImage: AnyObject, Sendable {
    /// The size of the image in points
    var size: CGSize { get }
}

/// Abstracts image loading and sprite sheet operations.
/// macOS uses NSImage/CGImage; Windows will use WIC or GDI+.
public protocol ImageProvider: Sendable {
    /// The concrete image type this provider works with
    associatedtype Image: PlatformImage

    /// Load an image from a file path
    func loadImage(fromPath path: String) -> Image?

    /// Crop a rectangular region from an image (for sprite sheet frame extraction)
    func cropImage(_ image: Image, to rect: CGRect) -> Image?

    /// Create an image from a cropped region at a specific display size
    func cropImage(_ image: Image, to rect: CGRect, displaySize: CGSize) -> Image?
}
