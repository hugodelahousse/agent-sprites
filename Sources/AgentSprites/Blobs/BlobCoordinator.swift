import AppKit
import SwiftUI
import AgentSpritesCore
import os.log

private func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

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
    private var blobAnimators: [String: SpriteAnimator] = [:]
    private var blobCharacters: [String: SpriteCharacter] = [:]
    private var blobHueRotations: [String: Double] = [:]
    private var nextBlobIndex: Int = 0
    private var blobHovered: [String: Bool] = [:]
    private var blobDragging: [String: Bool] = [:]
    private var messageWindows: [String: MessageWindowController] = [:]
    private var dismissedMessages: [String: SessionStatus] = [:]  // Track dismissed messages by status
    private var autoDismissTimers: [String: Timer] = [:]  // Auto-dismiss timers for waitingForInput
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var sessions: [SessionState] = []
    private var pendingRenderTime: Date?  // Track when session update happened, for timing logs

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

    /// Available character packs
    var availablePacks: [CharacterPack] {
        CharacterManager.shared.availablePacks
    }

    /// Currently selected character pack ID
    @Published var selectedPackId: String = "" {
        didSet {
            guard oldValue != selectedPackId, !selectedPackId.isEmpty else { return }
            CharacterManager.shared.selectPack(selectedPackId)
            reloadAllBlobs()
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        // Pre-load characters
        _ = CharacterManager.shared
        self.selectedPackId = CharacterManager.shared.selectedPackId ?? ""

        setupDisplayLink()

        if isEnabled {
            startAnimation()
        }
    }

    /// Reload all blobs with new characters (called when pack changes)
    private func reloadAllBlobs() {
        let currentSessions = sessions
        // Remove all existing blobs
        for id in blobWindows.keys {
            removeBlob(forSessionId: id)
        }
        nextBlobIndex = 0
        // Recreate blobs for current sessions
        for session in currentSessions {
            createBlob(for: session)
        }
        logger.info("Reloaded all blobs with new character pack: \(self.selectedPackId, privacy: .public)")
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Public API

    func updateSessions(_ newSessions: [SessionState]) {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) BlobCoordinator.updateSessions called with \(newSessions.count, privacy: .public) sessions")

        sessions = newSessions
        guard isEnabled else {
            logger.info("[TIMING] \(timestamp(), privacy: .public) Blobs disabled, skipping")
            return
        }

        let currentIds = Set(blobWindows.keys)
        let newIds = Set(newSessions.map { $0.id })

        // Remove blobs for sessions that no longer exist
        for id in currentIds.subtracting(newIds) {
            removeBlob(forSessionId: id)
        }

        // Add blobs for new sessions
        for session in newSessions {
            if blobWindows[session.id] == nil {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Creating new blob for session \(session.id.prefix(8), privacy: .public)")
                createBlob(for: session)
            } else {
                // Update session info for existing blob
                updateBlobInfo(for: session)
            }
        }

        pendingRenderTime = Date()  // Track for animation frame timing
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) BlobCoordinator.updateSessions complete (+\(String(format: "%.1f", elapsed), privacy: .public)ms)")
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

        // Get character for this blob (by path hash or sequential index)
        let character: SpriteCharacter
        if CharacterManager.shared.usesRandomCharacter {
            guard let char = CharacterManager.shared.character(forPath: session.workingDirectory) else {
                logger.error("Failed to load character for blob")
                return
            }
            character = char
        } else {
            let blobIndex = nextBlobIndex
            nextBlobIndex += 1
            guard let char = CharacterManager.shared.character(forIndex: blobIndex) else {
                logger.error("Failed to load character for blob")
                return
            }
            character = char
        }
        blobCharacters[session.id] = character

        let animator = SpriteAnimator(character: character)
        blobAnimators[session.id] = animator

        // Calculate hue rotation based on directory path hash (only used if in hueRotate mode)
        let hueRotation = CharacterManager.shared.usesHueRotation ? hueForPath(session.workingDirectory) : 0
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
        // Use deterministic djb2 hash for consistent color across restarts
        var hash: UInt64 = 5381
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)  // hash * 33 + char
        }
        // Map hash to 0-360 degree range
        return Double(hash % 360)
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
        blobCharacters.removeValue(forKey: id)
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
            y: screenPoint.y
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

        // Log time from session update to render
        if let pendingTime = pendingRenderTime {
            let renderDelay = Date().timeIntervalSince(pendingTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Animation frame rendering (+\(String(format: "%.1f", renderDelay), privacy: .public)ms from session update)")
            pendingRenderTime = nil
        }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        guard let screen = NSScreen.main else { return }
        let screenBounds = screen.visibleFrame

        // Get current window ledges
        let ledges = windowObserver.getLedges()

        // Collect all blob positions for avoidance behavior
        let allBlobPositions: [String: CGPoint] = blobPhysics.mapValues { $0.position }

        // Update all physics with awareness of other blobs
        for (id, _) in blobWindows {
            guard var physics = blobPhysics[id] else { continue }
            let isDragging = blobDragging[id] ?? false

            if !isDragging {
                // Get positions of other blobs (exclude self)
                let otherPositions = allBlobPositions.filter { $0.key != id }.map { $0.value }

                physics.groundY = screenBounds.minY
                physics.update(deltaTime: CGFloat(deltaTime), screenBounds: screenBounds, ledges: ledges, otherBlobs: otherPositions)
                blobPhysics[id] = physics
            }
        }

        // Third pass: update animators and windows
        for (id, window) in blobWindows {
            guard let physics = blobPhysics[id],
                  var animator = blobAnimators[id] else { continue }

            let isHovered = blobHovered[id] ?? false
            let isDragging = blobDragging[id] ?? false
            let hasMessageWindow = messageWindows[id] != nil

            // Get session status
            let session = sessions.first { $0.id == id }
            let status = session?.status ?? .idle

            // Update session info
            if let session = session {
                updateBlobInfo(for: session)
            }

            // Update animator - pass isMoving as false when hovered to play idle animation
            let effectivelyMoving = (isHovered || hasMessageWindow) && !isDragging ? false : physics.isMoving
            _ = animator.update(
                deltaTime: deltaTime,
                status: status,
                isMoving: effectivelyMoving,
                velocity: physics.horizontalVelocity,
                isDragging: isDragging,
                isFalling: physics.isFalling,
                isClimbing: physics.isClimbing,
                verticalVelocity: physics.velocity.y
            )
            blobAnimators[id] = animator

            // Get hue rotation and surface rotation
            let hueRotation = blobHueRotations[id] ?? 0
            let surfaceRotation = physics.surfaceRotation

            // Update window
            window.update(
                image: animator.currentImage,
                facingRight: animator.facingRight,
                screenPosition: physics.position,
                hueRotation: hueRotation,
                surfaceRotation: surfaceRotation
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
