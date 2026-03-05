import AppKit
import SpriteKit
import os
import SwiftUI
import AgentSpritesCore

private func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

/// Returns the screen containing the given point, or main screen as fallback
private func screenContaining(_ point: CGPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
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

    // Per-screen scene controllers (replaces per-sprite windows)
    private var sceneControllers: [CGDirectDisplayID: SpriteSceneController] = [:]
    private var spriteScreenAssignment: [String: CGDirectDisplayID] = [:]

    // Per-sprite state (unchanged)
    private var spritePhysics: [String: SpritePhysics] = [:]
    private var spriteAnimators: [String: SpriteAnimator] = [:]
    private var spriteCharacters: [String: SpriteCharacter] = [:]
    private var spriteHueRotations: [String: Double] = [:]
    private var spriteShaders: [String: SKShader] = [:]
    private var nextSpriteIndex: Int = 0
    private var spriteHovered: [String: Bool] = [:]
    private var spriteDragging: [String: Bool] = [:]

    // Session info for tooltips (moved from SpriteWindowController)
    private var spriteSessionInfo: [String: SessionInfo] = [:]
    private var spriteHasMessageWindow: [String: Bool] = [:]

    // Message windows (unchanged)
    private var messageWindows: [String: MessageWindowController] = [:]
    private var dismissedMessages: [String: SessionStatus] = [:]
    private var autoDismissTimers: [String: Timer] = [:]

    // Tooltip (shared, repositioned per-sprite)
    private var tooltipWindow: NSPanel?
    private var tooltipSessionId: String?

    // Animation — driven by SpriteKit's update loop (no CVDisplayLink)
    private var lastFrameTime: CFTimeInterval = 0
    private var sessions: [SessionState] = []
    private var pendingRenderTime: Date?
    private var lastUpdateFrameId: UInt64 = 0  // Dedup multiple scenes calling per frame

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

    var availablePacks: [CharacterPack] {
        CharacterManager.shared.availablePacks
    }

    @Published var selectedPackId: String = "" {
        didSet {
            guard oldValue != selectedPackId, !selectedPackId.isEmpty else { return }
            CharacterManager.shared.selectPack(selectedPackId)
            reloadAllSprites()
        }
    }

    /// Session info for tooltip display
    struct SessionInfo {
        var name: String = ""
        var status: String = ""
        var directory: String = ""
        var summary: String?
        var gitBranch: String?
    }

    init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)

        _ = CharacterManager.shared
        self.selectedPackId = CharacterManager.shared.selectedPackId ?? ""

        CharacterManager.shared.onMappingsRandomized = { [weak self] in
            Task { @MainActor in
                self?.reloadAllSprites()
            }
        }

        ledgeDebugOverlay.getSpriteBounds = { [weak self] in
            self?.getSpriteBounds() ?? []
        }

        observeScreenChanges()
        windowObserver.startObserving()
    }

    func randomizeMappings() {
        CharacterManager.shared.randomizeMappings()
    }

    private func reloadAllSprites() {
        let currentSessions = sessions
        // Remove all sprites from all scenes
        for id in spritePhysics.keys {
            removeSprite(forSessionId: id)
        }
        nextSpriteIndex = 0
        SpriteTextureCache.shared.clear()
        // Recreate sprites for current sessions
        for session in currentSessions {
            createSprite(for: session)
        }
        updateAnimationState()
        logger.info("Reloaded all sprites with new character pack: \(self.selectedPackId, privacy: .public)")
    }

    // MARK: - Screen Management

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenChange()
            }
        }
    }

    private func handleScreenChange() {
        let currentScreens = Set(NSScreen.screens.map { $0.displayID })
        let existingScreens = Set(sceneControllers.keys)

        // Remove controllers for disconnected screens
        for displayID in existingScreens.subtracting(currentScreens) {
            // Move any sprites on this screen to another screen
            let spritesOnScreen = spriteScreenAssignment.filter { $0.value == displayID }.map { $0.key }
            for sessionId in spritesOnScreen {
                if let newScreen = NSScreen.main {
                    reassignSprite(sessionId: sessionId, to: newScreen)
                }
            }
            sceneControllers[displayID]?.close()
            sceneControllers.removeValue(forKey: displayID)
        }

        // Update frames for existing screens
        for screen in NSScreen.screens {
            sceneControllers[screen.displayID]?.updateFrame(for: screen)
        }
    }

    /// Get or create a scene controller for the given screen
    private func ensureSceneController(for screen: NSScreen) -> SpriteSceneController {
        let displayID = screen.displayID
        if let existing = sceneControllers[displayID] {
            return existing
        }

        let controller = SpriteSceneController(screen: screen)
        setupSceneCallbacks(controller)
        sceneControllers[displayID] = controller
        if isEnabled {
            controller.show()
        }
        return controller
    }

    private func setupSceneCallbacks(_ controller: SpriteSceneController) {
        let scene = controller.scene

        scene.onFrameUpdate = { [weak self] currentTime in
            self?.animationFrame(currentTime: currentTime)
        }

        scene.onSpriteClick = { [weak self] sessionId in
            Task { @MainActor in
                await self?.handleSpriteClick(sessionId: sessionId)
            }
        }

        scene.onSpriteHoverEnter = { [weak self] sessionId in
            self?.handleHoverEnter(sessionId: sessionId)
        }

        scene.onSpriteHoverExit = { [weak self] sessionId in
            self?.handleHoverExit(sessionId: sessionId)
        }

        scene.onSpriteDragStart = { [weak self] sessionId in
            self?.handleDragStart(sessionId: sessionId)
        }

        scene.onSpriteDragUpdate = { [weak self] sessionId, screenPoint in
            self?.handleDragUpdate(sessionId: sessionId, screenPoint: screenPoint)
        }

        scene.onSpriteDragEnd = { [weak self] sessionId in
            self?.handleDragEnd(sessionId: sessionId)
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

        let currentIds = Set(spritePhysics.keys)
        let newIds = Set(newSessions.map { $0.id })

        // Remove sprites for sessions that no longer exist
        for id in currentIds.subtracting(newIds) {
            removeSprite(forSessionId: id)
        }

        // Add sprites for new sessions
        for session in newSessions {
            if spritePhysics[session.id] == nil {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Creating new sprite for session \(session.id.prefix(8), privacy: .public)")
                createSprite(for: session)
            } else {
                updateSpriteInfo(for: session)
            }
        }

        updateAnimationState()

        pendingRenderTime = Date()
        let elapsed = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) SpriteCoordinator.updateSessions complete (+\(String(format: "%.1f", elapsed), privacy: .public)ms)")
    }

    private func updateAnimationState() {
        for (_, controller) in sceneControllers {
            if isEnabled {
                controller.updatePauseState()
            } else {
                controller.setPaused(true)
            }
        }
    }

    // MARK: - Private - Sprite Management

    private func createSprite(for session: SessionState) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let screen = screens.randomElement() ?? screens[0]
        let screenBounds = screen.visibleFrame

        let margin: CGFloat = 80
        let startX = CGFloat.random(in: (screenBounds.minX + margin)...(screenBounds.maxX - margin))
        let groundY = screenBounds.minY

        // Spawn from top of screen
        let startY = screenBounds.maxY - 60

        var physics = SpritePhysics(x: startX, groundY: groundY)
        physics.position = CGPoint(x: startX, y: startY)
        spritePhysics[session.id] = physics

        // Get character
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

        let hueRotation = CharacterManager.shared.usesHueRotation ? hueForPath(session.workingDirectory) : 0
        spriteHueRotations[session.id] = hueRotation

        // Create shader if hue rotation is needed
        if hueRotation != 0 {
            spriteShaders[session.id] = HueRotationShader.shader(hueAngleDegrees: hueRotation)
        }

        spriteHovered[session.id] = false
        spriteDragging[session.id] = false
        spriteHasMessageWindow[session.id] = false

        // Store session info
        spriteSessionInfo[session.id] = SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )

        // Add sprite node to the scene for this screen
        let controller = ensureSceneController(for: screen)
        spriteScreenAssignment[session.id] = screen.displayID

        // Get initial texture
        if let image = animator.currentImage {
            let texture = SpriteTextureCache.shared.texture(for: image)
            let localPos = globalToLocal(physics.position, screen: screen)
            controller.scene.addSprite(sessionId: session.id, texture: texture, size: CGSize(width: 64, height: 64))
            controller.scene.updateSprite(
                sessionId: session.id,
                texture: texture,
                position: localPos,
                facingRight: true,
                surfaceRotation: 0,
                shader: spriteShaders[session.id]
            )
        }

        controller.updatePauseState()

        logger.debug("Created sprite for session: \(session.id, privacy: .public)")
    }

    private func hueForPath(_ path: String) -> Double {
        var hash: UInt64 = 5381 ^ CharacterManager.shared.mappingSeed
        for char in path.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(char)
        }
        return Double(hash % 360)
    }

    private func updateSpriteInfo(for session: SessionState) {
        spriteSessionInfo[session.id] = SessionInfo(
            name: session.displayName,
            status: session.status.displayName,
            directory: session.workingDirectory,
            summary: session.summary,
            gitBranch: session.gitBranch
        )
    }

    private func removeSprite(forSessionId id: String) {
        // Remove from scene
        if let displayID = spriteScreenAssignment[id],
           let controller = sceneControllers[displayID] {
            _ = controller.scene.removeSprite(sessionId: id)
            controller.updatePauseState()
        }

        spriteScreenAssignment.removeValue(forKey: id)
        spritePhysics.removeValue(forKey: id)
        spriteAnimators.removeValue(forKey: id)
        spriteCharacters.removeValue(forKey: id)
        spriteHueRotations.removeValue(forKey: id)
        spriteShaders.removeValue(forKey: id)
        spriteHovered.removeValue(forKey: id)
        spriteDragging.removeValue(forKey: id)
        spriteSessionInfo.removeValue(forKey: id)
        spriteHasMessageWindow.removeValue(forKey: id)

        // Clean up tooltip if it's for this sprite
        if tooltipSessionId == id {
            hideTooltip()
        }

        messageWindows[id]?.close()
        messageWindows.removeValue(forKey: id)
        dismissedMessages.removeValue(forKey: id)
        autoDismissTimers[id]?.invalidate()
        autoDismissTimers.removeValue(forKey: id)

        logger.debug("Removed sprite for session: \(id, privacy: .public)")
        updateAnimationState()
    }

    /// Reassign a sprite from its current screen to a new screen
    private func reassignSprite(sessionId: String, to newScreen: NSScreen) {
        let newDisplayID = newScreen.displayID

        // Remove from old scene
        if let oldDisplayID = spriteScreenAssignment[sessionId],
           let oldController = sceneControllers[oldDisplayID] {
            _ = oldController.scene.removeSprite(sessionId: sessionId)
            oldController.updatePauseState()
        }

        // Add to new scene
        let controller = ensureSceneController(for: newScreen)
        spriteScreenAssignment[sessionId] = newDisplayID

        if let animator = spriteAnimators[sessionId],
           let image = animator.currentImage,
           let physics = spritePhysics[sessionId] {
            let texture = SpriteTextureCache.shared.texture(for: image)
            let localPos = globalToLocal(physics.position, screen: newScreen)
            controller.scene.addSprite(sessionId: sessionId, texture: texture, size: CGSize(width: 64, height: 64))
            controller.scene.updateSprite(
                sessionId: sessionId,
                texture: texture,
                position: localPos,
                facingRight: animator.facingRight,
                surfaceRotation: physics.surfaceRotation,
                shader: spriteShaders[sessionId]
            )
        }

        controller.updatePauseState()
    }

    private func showAllSprites() {
        for (_, controller) in sceneControllers {
            controller.show()
        }
        for session in sessions {
            if spritePhysics[session.id] == nil {
                createSprite(for: session)
            }
            updateMessageWindow(for: session)
        }
    }

    private func hideAllSprites() {
        for (_, controller) in sceneControllers {
            controller.hide()
        }
        for (_, window) in messageWindows {
            window.hide()
        }
        hideTooltip()
    }

    private func handleSpriteClick(sessionId: String) async {
        guard let session = sessions.first(where: { $0.id == sessionId }) else { return }
        logger.debug("Sprite clicked for session: \(sessionId, privacy: .public)")
        await terminalFocuser.focusSession(session)
    }

    // MARK: - Private - Hover / Tooltip

    /// Track which sprite ID is currently hovered (driven by animation frame polling)
    private var lastHoveredId: String?

    /// Called each animation frame with the sprite ID under the mouse (or nil)
    private func updateHoverState(hoveredId: String?) {
        // No change
        guard hoveredId != lastHoveredId else { return }

        // Exit old hover
        if let oldId = lastHoveredId {
            spriteHovered[oldId] = false
            if tooltipSessionId == oldId {
                hideTooltip()
            }
        }

        // Enter new hover
        if let newId = hoveredId {
            spriteHovered[newId] = true
            showTooltip(for: newId)
        }

        lastHoveredId = hoveredId
    }

    private func handleHoverEnter(sessionId: String) {
        spriteHovered[sessionId] = true
        showTooltip(for: sessionId)
    }

    private func handleHoverExit(sessionId: String) {
        spriteHovered[sessionId] = false
        if tooltipSessionId == sessionId {
            hideTooltip()
        }
    }

    private func showTooltip(for sessionId: String) {
        // Don't show tooltip when message window is visible
        guard spriteHasMessageWindow[sessionId] != true else { return }

        if tooltipWindow == nil {
            createTooltipWindow()
        }
        tooltipSessionId = sessionId
        updateTooltipContent(sessionId: sessionId)
        positionTooltip(for: sessionId)
        tooltipWindow?.orderFront(nil)
    }

    private func hideTooltip() {
        tooltipWindow?.orderOut(nil)
        tooltipSessionId = nil
    }

    private func createTooltipWindow() {
        let tooltip = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        tooltip.isOpaque = false
        tooltip.backgroundColor = .clear
        tooltip.hasShadow = false
        tooltip.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)))
        tooltip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        tooltip.ignoresMouseEvents = true

        let info = SessionInfo()
        let tooltipView = TooltipView(info: info)
        let hostingView = NSHostingView(rootView: tooltipView)
        tooltip.contentView = hostingView

        tooltipWindow = tooltip
    }

    private func updateTooltipContent(sessionId: String) {
        guard let tooltip = tooltipWindow,
              let hostingView = tooltip.contentView as? NSHostingView<TooltipView>,
              let info = spriteSessionInfo[sessionId] else { return }
        hostingView.rootView = TooltipView(info: info)
    }

    private func positionTooltip(for sessionId: String) {
        guard let tooltip = tooltipWindow,
              let hostingView = tooltip.contentView as? NSHostingView<TooltipView>,
              let physics = spritePhysics[sessionId] else { return }

        let fittingSize = hostingView.fittingSize
        tooltip.setContentSize(fittingSize)

        // Position centered above the sprite (global Cocoa coordinates)
        let spritePos = physics.position
        let spriteSize: CGFloat = 64
        let gap: CGFloat = 8
        var tooltipOrigin = CGPoint(
            x: spritePos.x - fittingSize.width / 2,
            y: spritePos.y + spriteSize + gap
        )

        // Keep on screen
        let screen = screenContaining(spritePos) ?? NSScreen.main
        if let screen {
            let screenFrame = screen.visibleFrame

            if tooltipOrigin.y + fittingSize.height > screenFrame.maxY - 5 {
                tooltipOrigin.y = spritePos.y - fittingSize.height - gap
            }

            tooltipOrigin.x = max(screenFrame.minX + 5, min(screenFrame.maxX - fittingSize.width - 5, tooltipOrigin.x))
            tooltipOrigin.y = max(screenFrame.minY + 5, min(screenFrame.maxY - fittingSize.height - 5, tooltipOrigin.y))
        }

        tooltip.setFrameOrigin(tooltipOrigin)
    }

    // MARK: - Private - Drag Handling

    private func handleDragStart(sessionId: String) {
        spriteDragging[sessionId] = true
        spritePhysics[sessionId]?.startDrag()
        hideTooltip()
        logger.debug("Drag started for session: \(sessionId, privacy: .public)")
    }

    private func handleDragUpdate(sessionId: String, screenPoint: CGPoint) {
        guard spriteDragging[sessionId] == true else { return }

        let now = CACurrentMediaTime()
        let deltaTime = lastFrameTime > 0 ? now - lastFrameTime : 1.0 / 60.0

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

        if let dismissedStatus = dismissedMessages[session.id] {
            if dismissedStatus != session.status {
                dismissedMessages.removeValue(forKey: session.id)
            } else {
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

    // MARK: - Private - Coordinate Conversion

    /// Convert global Cocoa coordinates to scene-local coordinates
    private func globalToLocal(_ point: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(
            x: point.x - screen.frame.origin.x,
            y: point.y - screen.frame.origin.y
        )
    }

    /// Find the screen containing a point and return the display ID
    private func displayIDContaining(_ point: CGPoint) -> CGDirectDisplayID? {
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        return screen?.displayID
    }

    // MARK: - Private - Animation

    /// Called by SpriteKit's update loop from each scene.
    /// Multiple scenes may call this per frame; we dedup using a frame counter.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func animationFrame(currentTime: CFTimeInterval) {
        guard isEnabled else { return }

        // Dedup: SpriteKit's currentTime is the same for all scenes in a single frame
        // Use bit pattern as a cheap frame ID
        let frameId = currentTime.bitPattern
        guard frameId != lastUpdateFrameId else { return }
        lastUpdateFrameId = frameId

        if let pendingTime = pendingRenderTime {
            let renderDelay = Date().timeIntervalSince(pendingTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Animation frame rendering (+\(String(format: "%.1f", renderDelay), privacy: .public)ms from session update)")
            pendingRenderTime = nil
        }

        let rawDelta = lastFrameTime > 0 ? currentTime - lastFrameTime : 1.0 / 60.0
        let deltaTime = min(rawDelta, 0.5)  // Cap at 500ms to prevent huge jumps after pauses/throttle
        lastFrameTime = currentTime

        // Update mouse passthrough and detect hover from mouse position
        var hoveredIdThisFrame: String?
        for (_, controller) in sceneControllers {
            if let hitId = controller.updateMousePassthrough() {
                hoveredIdThisFrame = hitId
            }
        }

        // Drive hover state from mouse position (works even when panel was ignoring events)
        updateHoverState(hoveredId: hoveredIdThisFrame)

        let ledges = windowObserver.getLedges()
        let walls = windowObserver.getWalls()

        let allSpritePositions: [String: CGPoint] = spritePhysics.mapValues { $0.position }

        // Update all physics
        for id in spritePhysics.keys {
            guard var physics = spritePhysics[id] else { continue }
            let isDragging = spriteDragging[id] ?? false

            if !isDragging {
                guard let spriteScreen = screenContaining(physics.position) else { continue }
                let screenBounds = spriteScreen.visibleFrame

                let otherPositions = allSpritePositions.filter { $0.key != id }.map { $0.value }

                let isHovered = spriteHovered[id] ?? false
                let hasMessageWindow = messageWindows[id] != nil

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

        // Update animators and scene nodes
        for id in spritePhysics.keys {
            guard let physics = spritePhysics[id],
                  var animator = spriteAnimators[id] else { continue }

            let isHovered = spriteHovered[id] ?? false
            let isDragging = spriteDragging[id] ?? false
            let hasMessageWindow = messageWindows[id] != nil

            let session = sessions.first { $0.id == id }
            let status = session?.status ?? .idle

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

            // Determine facing direction with surface correction
            var effectiveFacingRight = animator.facingRight
            switch physics.currentSurface {
            case .leftWall, .windowWall(_, .left), .ceiling:
                effectiveFacingRight.toggle()
            default:
                break
            }

            // Check screen assignment and handle transitions
            let currentDisplayID = spriteScreenAssignment[id]
            let actualDisplayID = displayIDContaining(physics.position)

            if let actual = actualDisplayID, actual != currentDisplayID {
                // Sprite moved to a different screen
                if let newScreen = NSScreen.screens.first(where: { $0.displayID == actual }) {
                    reassignSprite(sessionId: id, to: newScreen)
                }
            }

            // Update the sprite node in the assigned scene
            if let displayID = spriteScreenAssignment[id],
               let controller = sceneControllers[displayID],
               let screen = NSScreen.screens.first(where: { $0.displayID == displayID }),
               let image = animator.currentImage {
                let texture = SpriteTextureCache.shared.texture(for: image)

                // Apply render offset for screen walls so feet appear at the screen edge.
                // Physics position stays at edgeMargin for wall detection, but visually
                // the sprite should be flush against the edge.
                var renderPos = physics.position
                switch physics.currentSurface {
                case .leftWall:
                    renderPos.x = screen.visibleFrame.minX
                case .rightWall:
                    renderPos.x = screen.visibleFrame.maxX
                default:
                    break
                }

                let localPos = globalToLocal(renderPos, screen: screen)

                controller.scene.updateSprite(
                    sessionId: id,
                    texture: texture,
                    position: localPos,
                    facingRight: effectiveFacingRight,
                    surfaceRotation: physics.surfaceRotation,
                    shader: spriteShaders[id]
                )
            }

            // Update message window
            if let session {
                updateMessageWindow(for: session)
                let hasMessage = messageWindows[id] != nil
                spriteHasMessageWindow[id] = hasMessage
                if let messageWindow = messageWindows[id] {
                    messageWindow.updatePosition(spritePosition: physics.position)
                }
            }

            // Update tooltip position if showing for this sprite
            if tooltipSessionId == id, spriteHovered[id] == true {
                positionTooltip(for: id)
            }
        }

        // Throttle frame rate: full speed only when sprites are moving/falling/dragging
        let needsFullRate = spritePhysics.contains { id, physics in
            let isDragging = spriteDragging[id] ?? false
            return physics.isMoving || physics.isFalling || isDragging
        }
        for (_, controller) in sceneControllers {
            controller.setNeedsFullFrameRate(needsFullRate)
        }
    }
}

// MARK: - Tooltip View

/// Tooltip view using terminal frame style
private struct TooltipView: View {
    let info: SpriteCoordinator.SessionInfo

    var body: some View {
        TerminalFrame {
            VStack(alignment: .leading, spacing: 4) {
                Text(info.summary ?? info.name)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(SpriteColors.terminalGreen)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(info.status.uppercased())
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(SpriteColors.terminalDimGreen)

                    if let branch = info.gitBranch, !branch.isEmpty {
                        Text("\u{2022}")
                            .font(.system(size: 9))
                            .foregroundColor(SpriteColors.terminalDimGreen.opacity(0.5))
                        Text(branch)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(SpriteColors.terminalDimGreen)
                    }
                }

                Text(info.directory)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(SpriteColors.terminalDimGreen.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(8)
        }
        .frame(minWidth: 150, maxWidth: 220)
    }
}
