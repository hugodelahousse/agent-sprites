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

/// Returns the screen containing the given point, or main screen as fallback
private func screenContaining(_ point: CGPoint) -> NSScreen? {
    // Find the screen that contains this point
    for screen in NSScreen.screens {
        if screen.frame.contains(point) {
            return screen
        }
    }
    // Fallback to main screen
    return NSScreen.main
}

/// Returns the combined bounds of all screens
private func allScreensBounds() -> CGRect {
    var bounds = CGRect.zero
    for screen in NSScreen.screens {
        bounds = bounds.union(screen.frame)
    }
    return bounds
}

/// Coordinates all character sprites and their animation
@MainActor
final class SpriteCoordinator: ObservableObject {
    private static let enabledKey = "FloatingSpritesEnabled"

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                showAllSprites()
            } else {
                hideAllSprites()
            }
            updateAnimationState()
        }
    }

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SpriteCoordinator")
    private var spriteWindows: [String: SpriteWindowController] = [:]
    private var spritePhysics: [String: SpritePhysics] = [:]
    private var spriteAnimators: [String: SpriteAnimator] = [:]
    private var spriteCharacters: [String: SpriteCharacter] = [:]
    private var spriteHueRotations: [String: Double] = [:]
    private var nextSpriteIndex: Int = 0
    private var spriteHovered: [String: Bool] = [:]
    private var spriteDragging: [String: Bool] = [:]
    private var messageWindows: [String: MessageWindowController] = [:]
    private var dismissedMessages: [String: SessionStatus] = [:]  // Track dismissed messages by status
    private var autoDismissTimers: [String: Timer] = [:]  // Auto-dismiss timers for waitingForInput
    private var displayLink: CVDisplayLink?
    private var lastFrameTime: CFTimeInterval = 0
    private var sessions: [SessionState] = []
    private var pendingRenderTime: Date?  // Track when session update happened, for timing logs
    private nonisolated(unsafe) var isProcessingFrame = false  // Skip frames when main thread is busy

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
            reloadAllSprites()
        }
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        // Pre-load characters
        _ = CharacterManager.shared
        self.selectedPackId = CharacterManager.shared.selectedPackId ?? ""

        // Set up callback for when mappings are randomized
        CharacterManager.shared.onMappingsRandomized = { [weak self] in
            Task { @MainActor in
                self?.reloadAllSprites()
            }
        }

        // Set up callback for debug overlay to get sprite bounds
        ledgeDebugOverlay.getSpriteBounds = { [weak self] in
            self?.getSpriteBounds() ?? []
        }

        setupDisplayLink()
        // Animation will start when sessions are added (via updateAnimationState)
    }

    /// Randomize folder-to-character/hue mappings
    func randomizeMappings() {
        CharacterManager.shared.randomizeMappings()
    }

    /// Reload all sprites with new characters (called when pack changes)
    private func reloadAllSprites() {
        let currentSessions = sessions
        // Remove all existing sprites
        for id in spriteWindows.keys {
            removeSprite(forSessionId: id)
        }
        nextSpriteIndex = 0
        // Recreate sprites for current sessions
        for session in currentSessions {
            createSprite(for: session)
        }
        logger.info("Reloaded all sprites with new character pack: \(self.selectedPackId, privacy: .public)")
    }

    deinit {
        if let displayLink = displayLink {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Public API

    func updateSessions(_ newSessions: [SessionState]) {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) SpriteCoordinator.updateSessions called with \(newSessions.count, privacy: .public) sessions")

        sessions = newSessions
        guard isEnabled else {
            logger.info("[TIMING] \(timestamp(), privacy: .public) Sprites disabled, skipping")
            return
        }

        let currentIds = Set(spriteWindows.keys)
        let newIds = Set(newSessions.map { $0.id })

        // Remove sprites for sessions that no longer exist
        for id in currentIds.subtracting(newIds) {
            removeSprite(forSessionId: id)
        }

        // Add sprites for new sessions
        for session in newSessions {
            if spriteWindows[session.id] == nil {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Creating new sprite for session \(session.id.prefix(8), privacy: .public)")
                createSprite(for: session)
            } else {
                // Update session info for existing sprite
                updateSpriteInfo(for: session)
            }
        }

        // Start/stop animation based on whether we have sprites
        updateAnimationState()

        pendingRenderTime = Date()  // Track for animation frame timing
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) SpriteCoordinator.updateSessions complete (+\(String(format: "%.1f", elapsed), privacy: .public)ms)")
    }

    /// Start or stop animation based on whether there are active sprites
    private func updateAnimationState() {
        let shouldAnimate = isEnabled && !spriteWindows.isEmpty
        let isAnimating = displayLink.map { CVDisplayLinkIsRunning($0) } ?? false

        if shouldAnimate && !isAnimating {
            startAnimation()
        } else if !shouldAnimate && isAnimating {
            stopAnimation()
        }
    }

    // MARK: - Private - Sprite Management

    private func createSprite(for session: SessionState) {
        // Pick a random screen to spawn on
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.randomElement() ?? screens[0]
        let screenBounds = screen.visibleFrame

        let margin: CGFloat = 80
        let startX = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
        let groundY = screenBounds.minY

        // Spawn from top of screen - they'll fall down
        let startY = screenBounds.maxY - 60

        var physics = SpritePhysics(x: startX, groundY: groundY)
        physics.position = CGPoint(x: startX, y: startY)  // Start at top
        spritePhysics[session.id] = physics

        // Get character for this sprite (by path hash or sequential index)
        let character: SpriteCharacter
        if CharacterManager.shared.usesRandomCharacter {
            guard let char = CharacterManager.shared.character(forPath: session.workingDirectory) else {
                logger.error("Failed to load character for sprite")
                return
            }
            character = char
        } else {
            let spriteIndex = nextSpriteIndex
            nextSpriteIndex += 1
            guard let char = CharacterManager.shared.character(forIndex: spriteIndex) else {
                logger.error("Failed to load character for sprite")
                return
            }
            character = char
        }
        spriteCharacters[session.id] = character

        let animator = SpriteAnimator(character: character)
        spriteAnimators[session.id] = animator

        // Calculate hue rotation based on directory path hash (only used if in hueRotate mode)
        let hueRotation = CharacterManager.shared.usesHueRotation ? hueForPath(session.workingDirectory) : 0
        spriteHueRotations[session.id] = hueRotation

        spriteHovered[session.id] = false
        spriteDragging[session.id] = false

        let window = SpriteWindowController(sessionId: session.id)

        window.onClick = { [weak self] in
            Task { @MainActor in
                await self?.handleSpriteClick(sessionId: session.id)
            }
        }

        window.onHoverChanged = { [weak self] isHovered in
            self?.spriteHovered[session.id] = isHovered
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
        window.sessionInfo = SpriteWindowController.SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )

        spriteWindows[session.id] = window
        window.show()

        logger.debug("Created sprite for session: \(session.id, privacy: .public)")
    }

    private func hueForPath(_ path: String) -> Double {
        // Use deterministic djb2 hash with seed for consistent but randomizable color
        var hash: UInt64 = 5381 ^ CharacterManager.shared.mappingSeed
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)  // hash * 33 + char
        }
        // Map hash to 0-360 degree range
        return Double(hash % 360)
    }

    private func updateSpriteInfo(for session: SessionState) {
        spriteWindows[session.id]?.sessionInfo = SpriteWindowController.SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )
    }

    private func removeSprite(forSessionId id: String) {
        spriteWindows[id]?.close()
        spriteWindows.removeValue(forKey: id)
        spritePhysics.removeValue(forKey: id)
        spriteAnimators.removeValue(forKey: id)
        spriteCharacters.removeValue(forKey: id)
        spriteHueRotations.removeValue(forKey: id)
        spriteHovered.removeValue(forKey: id)
        spriteDragging.removeValue(forKey: id)
        messageWindows[id]?.close()
        messageWindows.removeValue(forKey: id)
        dismissedMessages.removeValue(forKey: id)
        autoDismissTimers[id]?.invalidate()
        autoDismissTimers.removeValue(forKey: id)

        logger.debug("Removed sprite for session: \(id, privacy: .public)")

        // Stop animation if no more sprites
        updateAnimationState()
    }

    private func showAllSprites() {
        for session in sessions {
            if spriteWindows[session.id] == nil {
                createSprite(for: session)
            } else {
                spriteWindows[session.id]?.show()
            }
            updateMessageWindow(for: session)
        }
    }

    private func hideAllSprites() {
        for (_, window) in spriteWindows {
            window.hide()
        }
        for (_, window) in messageWindows {
            window.hide()
        }
    }

    private func handleSpriteClick(sessionId: String) async {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        logger.debug("Sprite clicked for session: \(sessionId, privacy: .public)")
        await terminalFocuser.focusSession(session)
    }

    // MARK: - Private - Drag Handling

    private func handleDragStart(sessionId: String) {
        spriteDragging[sessionId] = true
        spritePhysics[sessionId]?.startDrag()
        logger.debug("Drag started for session: \(sessionId, privacy: .public)")
    }

    private func handleDragUpdate(sessionId: String, screenPoint: CGPoint) {
        guard spriteDragging[sessionId] == true else { return }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0

        // Center the sprite on the cursor
        let spriteCenter = CGPoint(
            x: screenPoint.x,
            y: screenPoint.y
        )

        spritePhysics[sessionId]?.updateDrag(to: spriteCenter, deltaTime: CGFloat(deltaTime))
    }

    private func handleDragEnd(sessionId: String) {
        spriteDragging[sessionId] = false
        spritePhysics[sessionId]?.endDrag()
        logger.debug("Drag ended for session: \(sessionId, privacy: .public)")
    }

    // MARK: - Private - Message Windows

    private func updateMessageWindow(for session: SessionState) {
        let needsMessage = SpriteColors.needsAttention(for: session.status)

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
                messageWindows[session.id]?.update(status: session.status, summary: session.summary)
            }
        } else {
            messageWindows[session.id]?.close()
            messageWindows.removeValue(forKey: session.id)
            dismissedMessages.removeValue(forKey: session.id)
        }
    }

    private func createMessageWindow(for session: SessionState) {
        guard let physics = spritePhysics[session.id] else { return }

        let message = messageFor(status: session.status)
        let window = MessageWindowController(
            sessionId: session.id,
            sessionName: session.displayName,
            summary: session.summary,
            message: message,
            status: session.status,
            spritePosition: physics.position
        )

        window.onFocusTerminal = { [weak self] in
            Task { @MainActor in
                await self?.handleSpriteClick(sessionId: session.id)
            }
        }

        window.onDismiss = { [weak self] in
            self?.dismissMessage(for: session.id, status: session.status)
        }

        messageWindows[session.id] = window
        window.show()
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

    /// Get bounding boxes for all active sprites (for debug overlay)
    private func getSpriteBounds() -> [SpriteBounds] {
        spritePhysics.map { id, physics in
            let session = sessions.first { $0.id == id }
            return SpriteBounds(
                sessionId: id,
                position: physics.position,
                size: CGSize(width: 64, height: 64),
                status: session?.status
            )
        }
    }

    // MARK: - Private - Animation

    private func setupDisplayLink() {
        var displayLink: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        self.displayLink = displayLink

        guard let displayLink = displayLink else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            let coordinator = Unmanaged<SpriteCoordinator>.fromOpaque(userInfo!).takeUnretainedValue()

            // Skip frame if previous frame still processing (reduces CPU when main thread is busy)
            guard !coordinator.isProcessingFrame else { return kCVReturnSuccess }

            DispatchQueue.main.async {
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

    // swiftlint:disable:next cyclomatic_complexity
    private func animationFrame() {
        guard isEnabled else { return }

        isProcessingFrame = true
        defer { isProcessingFrame = false }

        // Log time from session update to render
        if let pendingTime = pendingRenderTime {
            let renderDelay = Date().timeIntervalSince(pendingTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Animation frame rendering (+\(String(format: "%.1f", renderDelay), privacy: .public)ms from session update)")
            pendingRenderTime = nil
        }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0
        lastFrameTime = now

        // Get current window ledges and walls
        let ledges = windowObserver.getLedges()
        let walls = windowObserver.getWalls()

        // Collect all sprite positions for avoidance behavior
        let allSpritePositions: [String: CGPoint] = spritePhysics.mapValues { $0.position }

        // Update all physics with awareness of other sprites
        for (id, _) in spriteWindows {
            guard var physics = spritePhysics[id] else { continue }
            let isDragging = spriteDragging[id] ?? false

            if !isDragging {
                // Get the screen containing this sprite
                guard let spriteScreen = screenContaining(physics.position) else { continue }
                let screenBounds = spriteScreen.visibleFrame

                // Get positions of other sprites (exclude self)
                let otherPositions = allSpritePositions.filter { $0.key != id }.map { $0.value }

                // Check if hovered or has message window
                let isHovered = spriteHovered[id] ?? false
                let hasMessageWindow = messageWindows[id] != nil

                // Don't wander when working, waiting for user, hovered, or showing message
                let session = sessions.first { $0.id == id }
                let shouldWander: Bool
                if isHovered || hasMessageWindow {
                    shouldWander = false
                } else {
                    switch session?.status {
                    case .working, .waitingForInput, .waitingForPermission:
                        shouldWander = false
                    default:
                        shouldWander = true
                    }
                }

                physics.groundY = screenBounds.minY
                physics.update(deltaTime: CGFloat(deltaTime), screenBounds: screenBounds, ledges: ledges, walls: walls, otherSprites: otherPositions, shouldWander: shouldWander)
                spritePhysics[id] = physics
            }
        }

        // Third pass: update animators and windows
        for (id, window) in spriteWindows {
            guard let physics = spritePhysics[id],
                  var animator = spriteAnimators[id] else { continue }

            let isHovered = spriteHovered[id] ?? false
            let isDragging = spriteDragging[id] ?? false
            let hasMessageWindow = messageWindows[id] != nil

            // Get session status (session info is updated in updateSessions, not here)
            let session = sessions.first { $0.id == id }
            let status = session?.status ?? .idle

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
            spriteAnimators[id] = animator

            // Get hue rotation and surface rotation
            let hueRotation = spriteHueRotations[id] ?? 0
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
                    messageWindow.updatePosition(spritePosition: physics.position)
                }
            }
        }
    }
}
