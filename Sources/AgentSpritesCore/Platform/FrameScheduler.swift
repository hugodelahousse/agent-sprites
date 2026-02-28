import Foundation

/// Abstracts display-synced animation timing.
/// macOS uses CVDisplayLink; Windows will use a Win32 timer or DXGI.
public protocol FrameScheduler: AnyObject, Sendable {
    /// Start the animation loop. The callback is invoked each frame on the main thread.
    /// - Parameter onFrame: Called with the delta time (seconds) since the last frame.
    func start(onFrame: @escaping @Sendable (_ deltaTime: Double) -> Void)

    /// Stop the animation loop.
    func stop()

    /// Whether the scheduler is currently running.
    var isRunning: Bool { get }

    /// Get the current high-resolution time in seconds.
    /// macOS uses CACurrentMediaTime(); Windows uses QueryPerformanceCounter.
    func currentTime() -> Double
}
