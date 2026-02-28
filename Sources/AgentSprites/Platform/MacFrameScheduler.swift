import AgentSpritesCore
import QuartzCore

/// Thread-safe boolean flag for cross-thread synchronization (e.g. CVDisplayLink callback → main thread)
private final class AtomicBool: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var _value: Bool

    init(_ value: Bool) { _value = value }

    var value: Bool {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _value
        }
        set {
            os_unfair_lock_lock(&lock)
            _value = newValue
            os_unfair_lock_unlock(&lock)
        }
    }
}

/// macOS frame scheduler using CVDisplayLink for display-synced animation
final class MacFrameScheduler: FrameScheduler, @unchecked Sendable {
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private let isProcessingFrame = AtomicBool(false)
    private var onFrame: (@Sendable (_ deltaTime: Double) -> Void)?

    var isRunning: Bool {
        guard let displayLink else { return false }
        return CVDisplayLinkIsRunning(displayLink)
    }

    init() {
        setupDisplayLink()
    }

    func start(onFrame: @escaping @Sendable (_ deltaTime: Double) -> Void) {
        self.onFrame = onFrame
        guard let displayLink else { return }
        CVDisplayLinkStart(displayLink)
        lastFrameTime = CACurrentMediaTime()
    }

    func stop() {
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        onFrame = nil
    }

    func currentTime() -> Double {
        CACurrentMediaTime()
    }

    private func setupDisplayLink() {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink

        guard let displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let scheduler = Unmanaged<MacFrameScheduler>.fromOpaque(userInfo!).takeUnretainedValue()

            // Skip frame if previous frame still processing
            guard !scheduler.isProcessingFrame.value else { return kCVReturnSuccess }

            DispatchQueue.main.async {
                scheduler.handleFrame()
            }

            return kCVReturnSuccess
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, userInfo)
    }

    private func handleFrame() {
        isProcessingFrame.value = true
        defer { isProcessingFrame.value = false }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        onFrame?(deltaTime)
    }

    deinit {
        if let displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }
}
