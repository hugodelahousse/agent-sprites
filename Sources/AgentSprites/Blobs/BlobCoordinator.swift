import AppKit
import SwiftUI
import AgentSpritesCore
import os.log

/// Coordinates all blob sprites and their animation
@MainActor
final class BlobCoordinator: ObservableObject {
    private static let enabledKey = "FloatingBlobsEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                startAnimation()
                showAllBlobs()
            } else {
                stopAnimation()
                hideAllBlobs()
            }
        }
    }

    private let logger = Logger(subsystem: "com.agentsprites", category: "BlobCoordinator")
    private var blobWindows: [String: BlobWindowController] = [:]
    private var blobPhysics: [String: SlimePhysics] = [:]
    private var blobAnimators: [String: SlimeAnimator] = [:]
    private var blobHueRotations: [String: Double] = [:]
    private var blobHovered: [String: Bool] = [:]
    private var blobDragging: [String: Bool] = [:]
    private var messageWindows: [String: MessageWindowController] = [:]
    private var dismissedMessages: [String: SessionStatus] = [:]  // Track dismissed messages by status
    private var autoDismissTimers: [String: Timer] = [:]  // Auto-dismiss timers for waitingForInput
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var sessions: [SessionState] = []

    private let terminalFocuser = TerminalFocuser()
    private let windowObserver = WindowObserver.shared
    private let ledgeDebugOverlay = LedgeDebugOverlay()

    @Published var debugLedgesEnabled: Bool = false {
        didSet {
            if debugLedgesEnabled {
                ledgeDebugOverlay.show()
            } else {
                ledgeDebugOverlay.hide()
            }
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        // Pre-load sprites
        _ = SlimeSpriteManager.shared

        setupDisplayLink()

        if isEnabled {
            startAnimation()
        }
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Public API

    func updateSessions(_ newSessions: [SessionState]) {
        sessions = newSessions
        guard isEnabled else { return }

        let currentIds = Set(blobWindows.keys)
        let newIds = Set(newSessions.map { $0.id })

        // Remove blobs for sessions that no longer exist
        for id in currentIds.subtracting(newIds) {
            removeBlob(forSessionId: id)
        }

        // Add blobs for new sessions
        for session in newSessions {
            if blobWindows[session.id] == nil {
                createBlob(for: session)
            } else {
                // Update session info for existing blob
                updateBlobInfo(for: session)
            }
        }
    }

    // MARK: - Private - Blob Management

    private func createBlob(for session: SessionState) {
        guard let screen = NSScreen.main else { return }
        let screenBounds = screen.visibleFrame

        let margin: CGFloat = 80
        let startX = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
        let groundY = screenBounds.minY

        // Spawn from top of screen - they'll fall down
        let startY = screenBounds.maxY - 60

        var physics = SlimePhysics(x: startX, groundY: groundY)
        physics.position = CGPoint(x: startX, y: startY)  // Start at top
        blobPhysics[session.id] = physics

        let animator = SlimeAnimator()
        blobAnimators[session.id] = animator

        // Calculate hue rotation based on directory path hash
        let hueRotation = hueForPath(session.workingDirectory)
        blobHueRotations[session.id] = hueRotation

        blobHovered[session.id] = false
        blobDragging[session.id] = false

        let window = BlobWindowController(sessionId: session.id)

        window.onClick = { [weak self] in
            Task { @MainActor in
                await self?.handleBlobClick(sessionId: session.id)
            }
        }

        window.onHoverChanged = { [weak self] isHovered in
            self?.blobHovered[session.id] = isHovered
        }

        window.onDragStart = { [weak self] in
            self?.handleDragStart(sessionId: session.id)
        }

        window.onDragUpdate = { [weak self] screenPoint in
            self?.handleDragUpdate(sessionId: session.id, screenPoint: screenPoint)
        }

        window.onDragEnd = { [weak self] in
            self?.handleDragEnd(sessionId: session.id)
        }

        // Set session info for hover tooltip
        window.sessionInfo = BlobWindowController.SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )

        blobWindows[session.id] = window
        window.show()

        logger.debug("Created blob for session: \(session.id, privacy: .public)")
    }

    private func hueForPath(_ path: String) -> Double {
        // Use hash of path to generate consistent hue rotation
        var hasher = Hasher()
        hasher.combine(path)
        let hash = hasher.finalize()
        // Map hash to 0-360 degree range
        return Double(abs(hash) % 360)
    }

    private func updateBlobInfo(for session: SessionState) {
        blobWindows[session.id]?.sessionInfo = BlobWindowController.SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )
    }

    private func removeBlob(forSessionId id: String) {
        blobWindows[id]?.close()
        blobWindows.removeValue(forKey: id)
        blobPhysics.removeValue(forKey: id)
        blobAnimators.removeValue(forKey: id)
        blobHueRotations.removeValue(forKey: id)
        blobHovered.removeValue(forKey: id)
        blobDragging.removeValue(forKey: id)
        messageWindows[id]?.close()
        messageWindows.removeValue(forKey: id)
        dismissedMessages.removeValue(forKey: id)
        autoDismissTimers[id]?.invalidate()
        autoDismissTimers.removeValue(forKey: id)

        logger.debug("Removed blob for session: \(id, privacy: .public)")
    }

    private func showAllBlobs() {
        for session in sessions {
            if blobWindows[session.id] == nil {
                createBlob(for: session)
            } else {
                blobWindows[session.id]?.show()
            }
            updateMessageWindow(for: session)
        }
    }

    private func hideAllBlobs() {
        for (_, window) in blobWindows {
            window.hide()
        }
        for (_, window) in messageWindows {
            window.hide()
        }
    }

    private func handleBlobClick(sessionId: String) async {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        logger.debug("Blob clicked for session: \(sessionId, privacy: .public)")
        await terminalFocuser.focusSession(session)
    }

    // MARK: - Private - Drag Handling

    private func handleDragStart(sessionId: String) {
        blobDragging[sessionId] = true
        blobPhysics[sessionId]?.startDrag()
        logger.debug("Drag started for session: \(sessionId, privacy: .public)")
    }

    private func handleDragUpdate(sessionId: String, screenPoint: CGPoint) {
        guard blobDragging[sessionId] == true else { return }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0

        // Center the blob on the cursor
        let blobCenter = CGPoint(
            x: screenPoint.x,
            y: screenPoint.y - 32  // Offset so cursor is above blob
        )

        blobPhysics[sessionId]?.updateDrag(to: blobCenter, deltaTime: CGFloat(deltaTime))
    }

    private func handleDragEnd(sessionId: String) {
        blobDragging[sessionId] = false
        blobPhysics[sessionId]?.endDrag()
        logger.debug("Drag ended for session: \(sessionId, privacy: .public)")
    }

    // MARK: - Private - Message Windows

    private func updateMessageWindow(for session: SessionState) {
        let needsMessage = BlobColors.needsAttention(for: session.status)

        // Check if user dismissed this message for this status
        if let dismissedStatus = dismissedMessages[session.id] {
            if dismissedStatus != session.status {
                // Status changed, clear the dismissed state
                dismissedMessages.removeValue(forKey: session.id)
            } else {
                // Still dismissed for this status, don't show
                return
            }
        }

        if needsMessage {
            if messageWindows[session.id] == nil {
                createMessageWindow(for: session)
            } else {
                messageWindows[session.id]?.update(status: session.status)
            }
        } else {
            messageWindows[session.id]?.close()
            messageWindows.removeValue(forKey: session.id)
            dismissedMessages.removeValue(forKey: session.id)
        }
    }

    private func createMessageWindow(for session: SessionState) {
        guard let physics = blobPhysics[session.id] else { return }

        let message = messageFor(status: session.status)
        let window = MessageWindowController(
            sessionId: session.id,
            sessionName: session.displayName,
            message: message,
            status: session.status,
            blobPosition: physics.position
        )

        window.onFocusTerminal = { [weak self] in
            Task { @MainActor in
                await self?.handleBlobClick(sessionId: session.id)
            }
        }

        window.onDismiss = { [weak self] in
            self?.dismissMessage(for: session.id, status: session.status)
        }

        messageWindows[session.id] = window
        window.show()

        // Auto-dismiss waitingForInput after 3 seconds
        if session.status == .waitingForInput {
            autoDismissTimers[session.id]?.invalidate()
            autoDismissTimers[session.id] = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.dismissMessage(for: session.id, status: session.status)
                }
            }
        }
    }

    private func dismissMessage(for sessionId: String, status: SessionStatus) {
        dismissedMessages[sessionId] = status
        messageWindows[sessionId]?.close()
        messageWindows.removeValue(forKey: sessionId)
        autoDismissTimers[sessionId]?.invalidate()
        autoDismissTimers.removeValue(forKey: sessionId)
    }

    private func messageFor(status: SessionStatus) -> String {
        switch status {
        case .waitingForInput:
            return "Waiting for your input..."
        case .waitingForPermission:
            return "Permission required"
        default:
            return "Attention needed"
        }
    }

    // MARK: - Private - Animation

    private func setupDisplayLink() {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink

        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let coordinator = Unmanaged<BlobCoordinator>.fromOpaque(userInfo!).takeUnretainedValue()

            Task { @MainActor in
                coordinator.animationFrame()
            }

            return kCVReturnSuccess
        }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(displayLink, callback, userInfo)
    }

    private func startAnimation() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStart(displayLink)
        lastFrameTime = CACurrentMediaTime()
        logger.debug("Animation started")
    }

    private func stopAnimation() {
        guard let displayLink = displayLink else { return }
        CVDisplayLinkStop(displayLink)
        logger.debug("Animation stopped")
    }

    private func animationFrame() {
        guard isEnabled else { return }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        guard let screen = NSScreen.main else { return }
        let screenBounds = screen.visibleFrame

        // Get current window ledges
        let ledges = windowObserver.getLedges()

        for (id, window) in blobWindows {
            guard var physics = blobPhysics[id],
                  var animator = blobAnimators[id] else { continue }

            let isHovered = blobHovered[id] ?? false
            let isDragging = blobDragging[id] ?? false
            let hasMessageWindow = messageWindows[id] != nil

            // Only update physics if not hovered and no message window (unless dragging)
            if isDragging || (!isHovered && !hasMessageWindow) {
                physics.groundY = screenBounds.minY
                physics.update(deltaTime: CGFloat(deltaTime), screenBounds: screenBounds, ledges: ledges)
                blobPhysics[id] = physics
            }

            // Get session status
            let session = sessions.first { $0.id == id }
            let status = session?.status ?? .idle

            // Update session info
            if let session = session {
                updateBlobInfo(for: session)
            }

            // Update animator - pass isMoving as false when hovered to play idle
            let effectivelyMoving = (isHovered || hasMessageWindow) && !isDragging ? false : physics.isMoving
            _ = animator.update(
                deltaTime: deltaTime,
                status: status,
                isMoving: effectivelyMoving,
                velocity: (isHovered || hasMessageWindow) && !isDragging ? 0 : physics.horizontalVelocity,
                isDragging: isDragging,
                isFalling: physics.isFalling
            )
            blobAnimators[id] = animator

            // Get hue rotation
            let hueRotation = blobHueRotations[id] ?? 0

            // Update window
            window.update(
                image: animator.currentImage,
                facingRight: animator.facingRight,
                screenPosition: physics.position,
                hueRotation: hueRotation
            )

            // Update message window
            if let session = session {
                updateMessageWindow(for: session)
                let hasMessage = messageWindows[id] != nil
                window.hasMessageWindow = hasMessage
                if let messageWindow = messageWindows[id] {
                    messageWindow.updatePosition(blobPosition: physics.position)
                }
            }
        }
    }
}
