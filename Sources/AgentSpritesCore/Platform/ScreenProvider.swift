import Foundation

/// Platform-independent display information
public struct DisplayInfo: Sendable {
    public let id: String
    public let frame: CGRect
    public let visibleFrame: CGRect
    public let isPrimary: Bool

    public init(id: String, frame: CGRect, visibleFrame: CGRect, isPrimary: Bool) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.isPrimary = isPrimary
    }
}

/// Platform-independent window information (for external windows, not our own)
public struct ExternalWindowInfo: Sendable {
    public let id: UInt32
    public let frame: CGRect
    public let ownerName: String?
    public let ownerPID: Int32
    public let layer: Int32

    public init(id: UInt32, frame: CGRect, ownerName: String?, ownerPID: Int32, layer: Int32) {
        self.id = id
        self.frame = frame
        self.ownerName = ownerName
        self.ownerPID = ownerPID
        self.layer = layer
    }
}

/// Abstracts display enumeration and external window listing.
/// macOS uses NSScreen + CGWindowListCopyWindowInfo; Windows will use EnumDisplayMonitors + EnumWindows.
public protocol ScreenProvider: Sendable {
    /// Get all connected displays
    func getAllDisplays() -> [DisplayInfo]

    /// Get the display containing a given point
    func getDisplay(containing point: CGPoint) -> DisplayInfo?

    /// Get the primary display
    func getPrimaryDisplay() -> DisplayInfo?

    /// Get all visible external windows (excluding our own, system UI, etc.)
    /// Window frames should be in Cocoa-style coordinates (origin at bottom-left of primary display).
    func getVisibleWindows() -> [ExternalWindowInfo]
}
