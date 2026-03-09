import AppKit
import SpriteKit
import os
import SwiftUI
import AgentSpritesCore

private let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()

private func timestamp() -> String {
    timestampFormatter.string(from: Date())
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

    // Per-screen scene controllers
    private var sceneControllers: [CGDirectDisplayID: SpriteSceneController] = [:]
    private var spriteScreenAssignment: [String: CGDirectDisplayID] = [:]

    // Per-sprite state — SpriteKit physics owns position; we track wander + surface state
    private var wanderBehaviors: [String: WanderBehavior] = [:]
    private var surfaceTrackers: [String: SurfaceTracker] = [:]
    private var spriteAnimators: [String: SpriteAnimator] = [:]
    private var spriteCharacters: [String: SpriteCharacter] = [:]
    private var spriteHueRotations: [String: Double] = [:]
    private var spriteShaders: [String: SKShader] = [:]
    private var nextSpriteIndex: Int = 0
    private var spriteHovered: [String: Bool] = [:]
    private var spriteDragging: [String: Bool] = [:]

    // Drag velocity tracking (moved from SpritePhysics)
    private var dragVelocityHistory: [String: [CGPoint]] = [:]
    private var dragLastPosition: [String: CGPoint] = [:]
    private var dragLastTime: [String: CFTimeInterval] = [:]
    private static let velocityHistoryCount = 5
    private static let maxThrowSpeed: CGFloat = 400

    // Session info for tooltips
    private var spriteSessionInfo: [String: SessionInfo] = [:]
    private var spriteHasMessageWindow: [String: Bool] = [:]

    // Message windows (AppKit NSPanel)
    private var messageWindows: [String: MessageWindowController] = [:]
    private var dismissedMessages: [String: SessionStatus] = [:]
    private var lastMessageStatus: [String: SessionStatus] = [:]
    private var autoDismissTimers: [String: Timer] = [:]

    // Tooltip (shared NSPanel, repositioned per-sprite)
    private var tooltipWindow: NSPanel?
    private var tooltipSessionId: String?

    // Animation — driven by SpriteKit's update loop
    private var lastFrameTime: CFTimeInterval = 0
    private var sessions: [SessionState] = []
    private var pendingRenderTime: Date?
    private var lastUpdateFrameId: UInt64 = 0
    private var lastLedgeCount: Int = -1

    /// Per-sprite cooldown to prevent rapid surface transitions at corners
    private var lastTransitionTime: [String: CFAbsoluteTime] = [:]
    private static let transitionCooldown: TimeInterval = 0.3

    private let terminalFocuser = TerminalFocuser()
    private let windowObserver = WindowObserver.shared
    private let ledgeDebugOverlay = LedgeDebugOverlay()

    // Physics constants matching original SpritePhysics
    private static let edgeMargin: CGFloat = 32

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
        if UserDefaults.standard.object(forKey: Self.enabledKey) == nil {
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
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
        for id in Array(wanderBehaviors.keys) {
            removeSprite(forSessionId: id)
        }
        nextSpriteIndex = 0
        SpriteTextureCache.shared.clear()
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

        for displayID in existingScreens.subtracting(currentScreens) {
            let spritesOnScreen = spriteScreenAssignment.filter { $0.value == displayID }.map { $0.key }
            for sessionId in spritesOnScreen {
                if let newScreen = NSScreen.main {
                    reassignSprite(sessionId: sessionId, to: newScreen)
                }
            }
            sceneControllers[displayID]?.close()
            sceneControllers.removeValue(forKey: displayID)
        }

        for screen in NSScreen.screens {
            sceneControllers[screen.displayID]?.updateFrame(for: screen)
        }
    }

    private func ensureSceneController(for screen: NSScreen) -> SpriteSceneController {
        let displayID = screen.displayID
        if let existing = sceneControllers[displayID] {
            return existing
        }

        let controller = SpriteSceneController(screen: screen)
        setupSceneCallbacks(controller)
        sceneControllers[displayID] = controller
        return controller
    }

    private func setupSceneCallbacks(_ controller: SpriteSceneController) {
        let scene = controller.scene

        scene.onFrameUpdate = { [weak self, weak controller] currentTime in
            controller?.didRenderFrame()
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

        let currentIds = Set(wanderBehaviors.keys)
        let newIds = Set(newSessions.map { $0.id })

        for id in currentIds.subtracting(newIds) {
            removeSprite(forSessionId: id)
        }

        for session in newSessions {
            if wanderBehaviors[session.id] == nil {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Creating new sprite for session \(session.id.prefix(8), privacy: .public)")
                createSprite(for: session)
            } else {
                updateSpriteInfo(for: session)
            }
        }

        for session in newSessions {
            updateMessageWindow(for: session)
            spriteHasMessageWindow[session.id] = messageWindows[session.id]?.isVisible ?? false
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

        // Spawn from top of screen
        let startY = screenBounds.maxY - 60

        // Initialize wander behavior and surface tracker
        var wander = WanderBehavior(startX: startX)
        wander.startIdling(stuck: true)
        wanderBehaviors[session.id] = wander
        surfaceTrackers[session.id] = SurfaceTracker()

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

        if hueRotation != 0 {
            spriteShaders[session.id] = HueRotationShader.shader(hueAngleDegrees: hueRotation)
        }

        spriteHovered[session.id] = false
        spriteDragging[session.id] = false
        spriteHasMessageWindow[session.id] = false

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

        if let image = animator.currentImage {
            let texture = SpriteTextureCache.shared.texture(for: image)
            let localPos = globalToLocal(CGPoint(x: startX, y: startY), screen: screen)
            controller.scene.addSprite(sessionId: session.id, texture: texture, size: CGSize(width: 64, height: 64))
            // Set initial position
            if let node = controller.scene.spriteNode(sessionId: session.id) {
                node.position = localPos
            }
            controller.scene.updateSpriteVisuals(
                sessionId: session.id,
                texture: texture,
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
        if let displayID = spriteScreenAssignment[id],
           let controller = sceneControllers[displayID] {
            _ = controller.scene.removeSprite(sessionId: id)
            controller.updatePauseState()
        }

        spriteScreenAssignment.removeValue(forKey: id)
        wanderBehaviors.removeValue(forKey: id)
        surfaceTrackers.removeValue(forKey: id)
        spriteAnimators.removeValue(forKey: id)
        spriteCharacters.removeValue(forKey: id)
        spriteHueRotations.removeValue(forKey: id)
        spriteShaders.removeValue(forKey: id)
        spriteHovered.removeValue(forKey: id)
        spriteDragging.removeValue(forKey: id)
        spriteSessionInfo.removeValue(forKey: id)
        spriteHasMessageWindow.removeValue(forKey: id)
        dragVelocityHistory.removeValue(forKey: id)
        dragLastPosition.removeValue(forKey: id)
        dragLastTime.removeValue(forKey: id)
        lastTransitionTime.removeValue(forKey: id)

        if tooltipSessionId == id {
            hideTooltip()
        }

        messageWindows[id]?.close()
        messageWindows.removeValue(forKey: id)
        dismissedMessages.removeValue(forKey: id)
        lastMessageStatus.removeValue(forKey: id)
        autoDismissTimers[id]?.invalidate()
        autoDismissTimers.removeValue(forKey: id)

        logger.debug("Removed sprite for session: \(id, privacy: .public)")
        updateAnimationState()
    }

    private func reassignSprite(sessionId: String, to newScreen: NSScreen) {
        let newDisplayID = newScreen.displayID

        if let oldDisplayID = spriteScreenAssignment[sessionId],
           let oldController = sceneControllers[oldDisplayID] {
            _ = oldController.scene.removeSprite(sessionId: sessionId)
            oldController.updatePauseState()
        }

        let controller = ensureSceneController(for: newScreen)
        spriteScreenAssignment[sessionId] = newDisplayID

        if let animator = spriteAnimators[sessionId],
           let image = animator.currentImage,
           let tracker = surfaceTrackers[sessionId] {
            let texture = SpriteTextureCache.shared.texture(for: image)
            controller.scene.addSprite(sessionId: sessionId, texture: texture, size: CGSize(width: 64, height: 64))

            // Transfer position from old node
            let spritePos = spriteGlobalPosition(sessionId: sessionId) ?? CGPoint(x: newScreen.frame.midX, y: newScreen.frame.midY)
            let localPos = globalToLocal(spritePos, screen: newScreen)
            if let node = controller.scene.spriteNode(sessionId: sessionId) {
                node.position = localPos
            }

            controller.scene.updateSpriteVisuals(
                sessionId: sessionId,
                texture: texture,
                facingRight: animator.facingRight,
                surfaceRotation: tracker.surfaceRotation,
                shader: spriteShaders[sessionId]
            )
        }

        controller.updatePauseState()
    }

    private func showAllSprites() {
        for session in sessions {
            if wanderBehaviors[session.id] == nil {
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

    // MARK: - Private - Physics Contact Handling

    // MARK: - Private - Hover / Tooltip

    private var lastHoveredId: String?

    private func updateHoverState(hoveredId: String?) {
        guard hoveredId != lastHoveredId else { return }

        if let oldId = lastHoveredId {
            spriteHovered[oldId] = false
            if tooltipSessionId == oldId {
                hideTooltip()
            }
        }

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
        // Don't show tooltip while sprite is falling or being dragged
        if surfaceTrackers[sessionId]?.currentSurface == .falling { return }
        if spriteDragging[sessionId] == true { return }

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
              let hostingView = tooltip.contentView as? NSHostingView<TooltipView> else { return }
        guard let spritePos = spriteGlobalPosition(sessionId: sessionId) else { return }

        let fittingSize = hostingView.fittingSize
        tooltip.setContentSize(fittingSize)

        let spriteSize: CGFloat = 64
        let gap: CGFloat = 8
        var tooltipOrigin = CGPoint(
            x: spritePos.x - fittingSize.width / 2,
            y: spritePos.y + spriteSize + gap
        )

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
        dragVelocityHistory[sessionId] = []
        dragLastPosition[sessionId] = spriteGlobalPosition(sessionId: sessionId)
        dragLastTime[sessionId] = CACurrentMediaTime()

        // Clear surface state
        surfaceTrackers[sessionId]?.currentSurface = .falling
        surfaceTrackers[sessionId]?.velocity = .zero
        surfaceTrackers[sessionId]?.clearAllCaches()

        hideTooltip()
        logger.debug("Drag started for session: \(sessionId, privacy: .public)")
    }

    private func handleDragUpdate(sessionId: String, screenPoint: CGPoint) {
        guard spriteDragging[sessionId] == true else { return }

        let now = CACurrentMediaTime()

        // Track velocity for throw using actual event timestamps
        if let lastPos = dragLastPosition[sessionId],
           let lastTime = dragLastTime[sessionId] {
            let dt = now - lastTime
            if dt > 0.001 {
                let dragVelocity = CGPoint(
                    x: (screenPoint.x - lastPos.x) / CGFloat(dt),
                    y: (screenPoint.y - lastPos.y) / CGFloat(dt)
                )
                var history = dragVelocityHistory[sessionId] ?? []
                history.append(dragVelocity)
                if history.count > Self.velocityHistoryCount {
                    history.removeFirst()
                }
                dragVelocityHistory[sessionId] = history
            }
        }
        dragLastPosition[sessionId] = screenPoint
        dragLastTime[sessionId] = now

        // Move the sprite node directly (body is non-dynamic)
        if let displayID = spriteScreenAssignment[sessionId],
           let controller = sceneControllers[displayID] {
            let localPos = CGPoint(
                x: screenPoint.x - controller.screenOrigin.x,
                y: screenPoint.y - controller.screenOrigin.y
            )
            controller.scene.spriteNode(sessionId: sessionId)?.position = localPos
        }
    }

    private func handleDragEnd(sessionId: String) {
        spriteDragging[sessionId] = false

        // Compute throw velocity from history
        if let history = dragVelocityHistory[sessionId], !history.isEmpty {
            let avg = history.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let count = CGFloat(history.count)
            surfaceTrackers[sessionId]?.velocity = CGPoint(
                x: max(-Self.maxThrowSpeed, min(Self.maxThrowSpeed, avg.x / count)),
                y: max(-Self.maxThrowSpeed, min(Self.maxThrowSpeed, avg.y / count))
            )
        }

        surfaceTrackers[sessionId]?.currentSurface = .falling
        surfaceTrackers[sessionId]?.clearAllCaches()
        dragVelocityHistory.removeValue(forKey: sessionId)
        dragLastPosition.removeValue(forKey: sessionId)
        dragLastTime.removeValue(forKey: sessionId)

        logger.debug("Drag ended for session: \(sessionId, privacy: .public)")
    }

    // MARK: - Private - Message Windows

    private func updateMessageWindow(for session: SessionState) {
        let needsMessage = SpriteColors.needsAttention(for: session.status)
        let lastNeeded = lastMessageStatus[session.id].map { SpriteColors.needsAttention(for: $0) }

        if lastNeeded == needsMessage, lastMessageStatus[session.id] == session.status {
            return
        }
        lastMessageStatus[session.id] = session.status

        if let dismissedStatus = dismissedMessages[session.id] {
            if dismissedStatus != session.status {
                dismissedMessages.removeValue(forKey: session.id)
            } else {
                return
            }
        }

        if needsMessage {
            if let existing = messageWindows[session.id] {
                existing.update(status: session.status, summary: session.summary)
                existing.show()
            } else {
                createMessageWindow(for: session)
            }
        } else if let window = messageWindows[session.id] {
            window.hide()
        }
    }

    private func createMessageWindow(for session: SessionState) {
        guard let spritePos = spriteGlobalPosition(sessionId: session.id) else { return }

        let message = messageFor(status: session.status)
        let window = MessageWindowController(
            sessionId: session.id,
            sessionName: session.displayName,
            summary: session.summary,
            message: message,
            status: session.status,
            spritePosition: spritePos
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
        wanderBehaviors.keys.compactMap { id in
            guard let pos = spriteGlobalPosition(sessionId: id) else { return nil }
            let session = sessions.first { $0.id == id }
            return SpriteBounds(
                sessionId: id,
                position: pos,
                size: CGSize(width: 64, height: 64),
                status: session?.status
            )
        }
    }

    // MARK: - Private - Coordinate Conversion

    /// Get sprite position in global Cocoa coordinates (from SKNode position + cached screen origin)
    private func spriteGlobalPosition(sessionId: String) -> CGPoint? {
        guard let displayID = spriteScreenAssignment[sessionId],
              let controller = sceneControllers[displayID],
              let node = controller.scene.spriteNode(sessionId: sessionId) else { return nil }

        let origin = controller.screenOrigin
        return CGPoint(
            x: node.position.x + origin.x,
            y: node.position.y + origin.y
        )
    }

    /// Convert global Cocoa coordinates to scene-local coordinates
    private func globalToLocal(_ point: CGPoint, screen: NSScreen) -> CGPoint {
        CGPoint(
            x: point.x - screen.frame.origin.x,
            y: point.y - screen.frame.origin.y
        )
    }

    private func displayIDContaining(_ point: CGPoint) -> CGDirectDisplayID? {
        // Use cached screen frames from controllers to avoid NSScreen.screens lookups
        for (displayID, controller) in sceneControllers {
            if controller.screenFrame.contains(point) {
                return displayID
            }
        }
        return sceneControllers.keys.first
    }

    // MARK: - Private - Animation

    // Called by SpriteKit's update loop from each scene.
    // Multiple scenes may call this per frame; we dedup using a frame counter.
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    private func animationFrame(currentTime: CFTimeInterval) {
        guard isEnabled else { return }

        let frameId = currentTime.bitPattern
        guard frameId != lastUpdateFrameId else { return }
        lastUpdateFrameId = frameId

        os_signpost(.begin, log: AppSignposts.renderLoop, name: "AnimationFrame")

        if let pendingTime = pendingRenderTime {
            let renderDelay = Date().timeIntervalSince(pendingTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Animation frame rendering (+\(String(format: "%.1f", renderDelay), privacy: .public)ms from session update)")
            pendingRenderTime = nil
        }

        let rawDelta = lastFrameTime > 0 ? currentTime - lastFrameTime : 1.0 / 60.0
        let deltaTime = min(rawDelta, 0.5)
        lastFrameTime = currentTime

        // Update mouse passthrough and detect hover
        var hoveredIdThisFrame: String?
        for (_, controller) in sceneControllers {
            if let hitId = controller.updateMousePassthrough() {
                hoveredIdThisFrame = hitId
            }
        }
        updateHoverState(hoveredId: hoveredIdThisFrame)

        // Early exit if no sprites to update
        guard !wanderBehaviors.isEmpty else {
            os_signpost(.end, log: AppSignposts.renderLoop, name: "AnimationFrame")
            return
        }

        let ledges = windowObserver.getLedges()
        let walls = windowObserver.getWalls()

        // Detect ledge layout changes
        let ledgesChanged = ledges.count != lastLedgeCount
        lastLedgeCount = ledges.count

        // Set sprites on vanished ledges to falling
        if ledgesChanged {
            for id in wanderBehaviors.keys {
                guard var tracker = surfaceTrackers[id],
                      tracker.currentSurface == .ledge,
                      let ledgeY = tracker.currentLedgeY else { continue }

                let globalPos = spriteGlobalPosition(sessionId: id) ?? .zero
                let ledgeStillExists = ledges.contains { ledge in
                    abs(ledge.y - ledgeY) < 10 && ledge.contains(x: globalPos.x)
                }
                if !ledgeStillExists {
                    tracker.startFalling()
                    tracker.velocity = CGPoint(x: 0, y: -50)
                    surfaceTrackers[id] = tracker
                    wanderBehaviors[id]?.startIdling(stuck: true)
                }
            }
        }

        // Collect all sprite positions for avoidance
        var allSpritePositions: [String: CGPoint] = [:]
        for id in wanderBehaviors.keys {
            if let pos = spriteGlobalPosition(sessionId: id) {
                allSpritePositions[id] = pos
            }
        }

        let dt = CGFloat(deltaTime)

        // Update wander behaviors, physics, and positions
        for id in wanderBehaviors.keys {
            guard var wander = wanderBehaviors[id],
                  var tracker = surfaceTrackers[id] else { continue }
            let isDragging = spriteDragging[id] ?? false
            guard !isDragging else { continue }

            guard var globalPos = allSpritePositions[id] else { continue }
            guard let assignedDisplayID = spriteScreenAssignment[id],
                  let spriteController = sceneControllers[assignedDisplayID] else { continue }
            let screenBounds = spriteController.screenVisibleFrame

            let isHovered = spriteHovered[id] ?? false
            let hasMessageWindow = messageWindows[id]?.isVisible ?? false

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

            // Sprite avoidance every 10th frame
            wander.frameCount &+= 1
            if shouldWander, wander.frameCount.isMultiple(of: 10) {
                let otherPositions = allSpritePositions.filter { $0.key != id }.map { $0.value }
                wander.checkForSpritesAhead(context: WanderBehavior.AvoidanceContext(
                    surface: tracker.currentSurface,
                    position: globalPos,
                    velocity: tracker.velocity,
                    otherSprites: otherPositions,
                    screenBounds: screenBounds,
                    ledges: ledges,
                    groundY: screenBounds.minY,
                    ledgeMinX: tracker.currentLedgeMinX,
                    ledgeMaxX: tracker.currentLedgeMaxX
                ))
            }

            // Get desired speed from wander
            let desiredSpeed = wander.update(context: WanderBehavior.UpdateContext(
                surface: tracker.currentSurface,
                position: globalPos,
                screenBounds: screenBounds,
                ledges: ledges,
                walls: walls,
                wallMinY: tracker.currentWallMinY,
                wallMaxY: tracker.currentWallMaxY,
                groundY: screenBounds.minY,
                ledgeY: tracker.currentLedgeY,
                shouldWander: shouldWander
            ))

            // Apply movement based on surface
            let previousY = globalPos.y
            switch tracker.currentSurface {
            case .floor, .ledge:
                tracker.velocity = CGPoint(x: desiredSpeed, y: 0)
                globalPos.x += desiredSpeed * dt
                // Clamp to surface bounds
                let minX = (tracker.currentLedgeMinX ?? screenBounds.minX) + 10
                let maxX = (tracker.currentLedgeMaxX ?? screenBounds.maxX) - 10
                globalPos.x = max(minX, min(maxX, globalPos.x))
            case .ceiling:
                tracker.velocity = CGPoint(x: desiredSpeed, y: 0)
                globalPos.x += desiredSpeed * dt
                globalPos.x = max(screenBounds.minX + 10, min(screenBounds.maxX - 10, globalPos.x))
            case .leftWall, .rightWall, .windowWall:
                tracker.velocity = CGPoint(x: 0, y: desiredSpeed)
                globalPos.y += desiredSpeed * dt
            case .falling:
                // Apply gravity and move
                globalPos = tracker.update(position: globalPos, dt: dt)
            }

            // Handle surface transitions
            handleSurfaceTransitions(
                id: id,
                tracker: &tracker,
                wander: &wander,
                globalPos: &globalPos,
                previousY: previousY,
                screenBounds: screenBounds,
                ledges: ledges,
                walls: walls
            )

            // Update node position
            let localPos = CGPoint(
                x: globalPos.x - spriteController.screenOrigin.x,
                y: globalPos.y - spriteController.screenOrigin.y
            )
            spriteController.scene.spriteNode(sessionId: id)?.position = localPos
            allSpritePositions[id] = globalPos

            wanderBehaviors[id] = wander
            surfaceTrackers[id] = tracker
        }

        // Update animators and scene nodes
        for id in wanderBehaviors.keys {
            guard let tracker = surfaceTrackers[id],
                  var animator = spriteAnimators[id] else { continue }

            let isHovered = spriteHovered[id] ?? false
            let isDragging = spriteDragging[id] ?? false
            let hasMessageWindow = messageWindows[id]?.isVisible ?? false

            let session = sessions.first { $0.id == id }
            let status = session?.status ?? .idle

            let vel = tracker.velocity

            let isMoving: Bool
            switch tracker.currentSurface {
            case .leftWall, .rightWall, .windowWall:
                isMoving = abs(vel.y) > 2
            default:
                isMoving = abs(vel.x) > 2
            }

            let isFalling = tracker.currentSurface == .falling && vel.y < -10

            let effectivelyMoving = (isHovered || hasMessageWindow) && !isDragging ? false : isMoving
            _ = animator.update(
                deltaTime: deltaTime,
                status: status,
                isMoving: effectivelyMoving,
                velocity: vel.x,
                isDragging: isDragging,
                isFalling: isFalling,
                isClimbing: tracker.isClimbing,
                verticalVelocity: vel.y
            )
            spriteAnimators[id] = animator

            // Determine facing direction with surface correction
            var effectiveFacingRight = animator.facingRight
            switch tracker.currentSurface {
            case .leftWall, .windowWall(_, .left), .ceiling:
                effectiveFacingRight.toggle()
            default:
                break
            }

            // Check screen assignment and handle transitions
            if let globalPos = allSpritePositions[id] {
                let currentDisplayID = spriteScreenAssignment[id]
                let actualDisplayID = displayIDContaining(globalPos)

                if let actual = actualDisplayID, actual != currentDisplayID {
                    if let screen = NSScreen.screens.first(where: { $0.displayID == actual }) {
                        reassignSprite(sessionId: id, to: screen)
                    }
                }
            }

            // Update sprite visuals
            if let displayID = spriteScreenAssignment[id],
               let controller = sceneControllers[displayID],
               let image = animator.currentImage {
                let texture = SpriteTextureCache.shared.texture(for: image)

                controller.scene.updateSpriteVisuals(
                    sessionId: id,
                    texture: texture,
                    facingRight: effectiveFacingRight,
                    surfaceRotation: tracker.surfaceRotation,
                    shader: spriteShaders[id]
                )
            }
        }

        // Update message window positions (only when sprite is on a surface and moving)
        for id in wanderBehaviors.keys {
            guard let tracker = surfaceTrackers[id],
                  tracker.currentSurface != .falling,
                  let pos = allSpritePositions[id],
                  messageWindows[id]?.isVisible == true else { continue }
            let vel = tracker.velocity
            if abs(vel.x) > 2 || abs(vel.y) > 2 {
                messageWindows[id]?.updatePosition(spritePosition: pos)
            }
        }

        // Update tooltip position (only when sprite is on a surface)
        if let tooltipId = tooltipSessionId,
           let tracker = surfaceTrackers[tooltipId],
           tracker.currentSurface == .falling {
            // Sprite started falling — hide tooltip
            hideTooltip()
        } else if let tooltipId = tooltipSessionId, spriteHovered[tooltipId] == true {
            positionTooltip(for: tooltipId)
        }

        // Throttle frame rate per screen
        var activeDisplayIDs: Set<CGDirectDisplayID> = []
        for id in wanderBehaviors.keys {
            guard let displayID = spriteScreenAssignment[id] else { continue }
            if activeDisplayIDs.contains(displayID) { continue }

            let isDragging = spriteDragging[id] ?? false
            let isFalling = surfaceTrackers[id]?.currentSurface == .falling
            let isWalking = wanderBehaviors[id]?.wanderState == .walking
            let vel = surfaceTrackers[id]?.velocity ?? .zero
            let hasVelocity = abs(vel.x) > 2 || abs(vel.y) > 2

            if isDragging || isFalling || isWalking || hasVelocity {
                activeDisplayIDs.insert(displayID)
            }
        }
        for (displayID, controller) in sceneControllers {
            controller.setNeedsFullFrameRate(activeDisplayIDs.contains(displayID))
        }

        os_signpost(.end, log: AppSignposts.renderLoop, name: "AnimationFrame")
    }

    // MARK: - Private - Surface Transitions

    // Handle surface-specific movement transitions (wall climbing, ceiling, landing)
    // swiftlint:disable:next cyclomatic_complexity function_body_length function_parameter_count
    private func handleSurfaceTransitions(
        id: String,
        tracker: inout SurfaceTracker,
        wander: inout WanderBehavior,
        globalPos: inout CGPoint,
        previousY: CGFloat,
        screenBounds: CGRect,
        ledges: [WindowObserver.Ledge],
        walls: [WindowObserver.Wall]
    ) {
        // Cooldown prevents rapid back-and-forth transitions at corners.
        // Only applies to surface-to-surface transitions — falling is never blocked.
        let now = CFAbsoluteTimeGetCurrent()
        if tracker.currentSurface != .falling {
            if let lastTime = lastTransitionTime[id], now - lastTime < Self.transitionCooldown {
                return
            }
        }

        let previousSurface = tracker.currentSurface

        switch tracker.currentSurface {
        case .floor, .ledge:
            // Check for wall collision
            for wall in walls {
                guard wall.contains(y: globalPos.y, margin: 10) else { continue }
                let wallMargin: CGFloat = 5
                if tracker.velocity.x > 0 && wall.side == .left {
                    if globalPos.x >= wall.x - wallMargin && globalPos.x < wall.x + 20 {
                        tracker.startClimbingWindowWall(wall: wall)
                        tracker.velocity = CGPoint(x: 0, y: WanderBehavior.climbSpeed)
                        wander.targetPosition = wall.maxY - 10
                        wander.wanderState = .walking
                        break
                    }
                }
                if tracker.velocity.x < 0 && wall.side == .right {
                    if globalPos.x <= wall.x + wallMargin && globalPos.x > wall.x - 20 {
                        tracker.startClimbingWindowWall(wall: wall)
                        tracker.velocity = CGPoint(x: 0, y: WanderBehavior.climbSpeed)
                        wander.targetPosition = wall.maxY - 10
                        wander.wanderState = .walking
                        break
                    }
                }
            }

            // Only check further transitions if we didn't already transition above
            if tracker.currentSurface == previousSurface {
                // Check for screen edge → start wall climbing
                if globalPos.x <= screenBounds.minX + Self.edgeMargin + 5 {
                    tracker.startClimbingScreenWall(isLeftWall: true)
                    tracker.velocity = CGPoint(x: 0, y: WanderBehavior.climbSpeed)
                    wander.targetPosition = screenBounds.maxY - 60
                    wander.wanderState = .walking
                } else if globalPos.x >= screenBounds.maxX - Self.edgeMargin - 5 {
                    tracker.startClimbingScreenWall(isLeftWall: false)
                    tracker.velocity = CGPoint(x: 0, y: WanderBehavior.climbSpeed)
                    wander.targetPosition = screenBounds.maxY - 60
                    wander.wanderState = .walking
                }

                // Check if walked off ledge
                if tracker.currentSurface == .ledge {
                    let leftEdge = (tracker.currentLedgeMinX ?? screenBounds.minX) + 10
                    let rightEdge = (tracker.currentLedgeMaxX ?? screenBounds.maxX) - 10
                    if globalPos.x < leftEdge || globalPos.x > rightEdge {
                        tracker.startFalling()
                    }
                }
            }

        case .leftWall, .rightWall:
            let isLeftWall = tracker.currentSurface == .leftWall
            let ceilingY = screenBounds.maxY - 50

            if globalPos.y >= ceilingY {
                tracker.transitionToCeiling()
                tracker.velocity = CGPoint(x: isLeftWall ? WanderBehavior.moveSpeed : -WanderBehavior.moveSpeed, y: 0)
                wander.targetPosition = CGFloat.random(in: (screenBounds.minX + 100)...(screenBounds.maxX - 100))
                wander.wanderState = .walking
            } else if globalPos.y <= screenBounds.minY + 5 {
                tracker.landOnFloor(y: screenBounds.minY, screenBounds: screenBounds)
                globalPos.y = screenBounds.minY
                wander.targetPosition = globalPos.x
                wander.startIdling(stuck: false)
            }

        case .windowWall(let wallX, let side):
            guard let wallMinY = tracker.currentWallMinY,
                  let wallMaxY = tracker.currentWallMaxY else {
                tracker.startFalling()
                break
            }

            // Top transition — land on ledge
            if globalPos.y >= wallMaxY - 5 {
                if let ledge = ledges.first(where: { abs($0.y - wallMaxY) < 10 && $0.contains(x: globalPos.x) }) {
                    tracker.landOnLedge(ledge)
                } else {
                    tracker.currentSurface = .ledge
                    tracker.currentLedgeY = wallMaxY
                    if side == .left {
                        tracker.currentLedgeMinX = wallX
                        tracker.currentLedgeMaxX = wallX + 200
                    } else {
                        tracker.currentLedgeMinX = wallX - 200
                        tracker.currentLedgeMaxX = wallX
                    }
                }
                globalPos.y = wallMaxY
                tracker.velocity = .zero
                wander.targetPosition = globalPos.x
                wander.startIdling(stuck: false)
            } else if globalPos.y <= wallMinY + 5 {
                // Bottom transition
                if let ledge = ledges.first(where: { abs($0.y - wallMinY) < 10 && $0.contains(x: globalPos.x) }) {
                    tracker.landOnLedge(ledge)
                    globalPos.y = ledge.y
                } else if wallMinY <= screenBounds.minY + 10 {
                    tracker.landOnFloor(y: screenBounds.minY, screenBounds: screenBounds)
                    globalPos.y = screenBounds.minY
                } else {
                    tracker.startFalling()
                }
                tracker.velocity = .zero
                wander.targetPosition = globalPos.x
                wander.startIdling(stuck: true)
            }

        case .ceiling:
            // Check for wall transitions at edges
            if globalPos.x <= screenBounds.minX + Self.edgeMargin + 5 {
                tracker.startClimbingScreenWall(isLeftWall: true)
                tracker.velocity = CGPoint(x: 0, y: -WanderBehavior.climbSpeed)
                wander.targetPosition = screenBounds.minY + 100
                wander.wanderState = .walking
            } else if globalPos.x >= screenBounds.maxX - Self.edgeMargin - 5 {
                tracker.startClimbingScreenWall(isLeftWall: false)
                tracker.velocity = CGPoint(x: 0, y: -WanderBehavior.climbSpeed)
                wander.targetPosition = screenBounds.minY + 100
                wander.wanderState = .walking
            } else if wander.checkForLedgeDrop(position: globalPos, screenBounds: screenBounds, ledges: ledges) {
                tracker.startFalling()
                tracker.velocity = CGPoint(x: 0, y: -50)
            }

        case .falling:
            // Check for landing
            if let landPos = tracker.checkLanding(
                position: globalPos,
                previousY: previousY,
                screenBounds: screenBounds,
                ledges: ledges
            ) {
                globalPos = landPos
                wander.startIdling(stuck: true)
            }

            // Clamp to screen bounds horizontally
            globalPos.x = max(screenBounds.minX + 10, min(screenBounds.maxX - 10, globalPos.x))

            // Clamp to floor (safety net)
            if globalPos.y < screenBounds.minY {
                globalPos.y = screenBounds.minY
                tracker.landOnFloor(y: screenBounds.minY, screenBounds: screenBounds)
                wander.startIdling(stuck: true)
            }
        }

        // Record transition time to prevent rapid back-and-forth at corners
        if tracker.currentSurface != previousSurface {
            lastTransitionTime[id] = now
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
