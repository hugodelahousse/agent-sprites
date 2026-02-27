import Foundation
import AgentSpritesCore
import os.log

private let logger = Logger(subsystem: "com.agentsprites.app", category: "SessionManager")

private func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

/// Manages session states in memory, processing events from CLI notifications
actor SessionManager {
    private var store = SessionStore()
    private var doneTimers: [String: Task<Void, Never>] = [:]
    /// Recently removed session IDs with removal timestamp (prevents race with background updates)
    private var recentlyRemoved: [String: Date] = [:]
    /// How long to block re-creation of removed sessions
    private let removalBlockDuration: TimeInterval = 10.0

    /// Process a session event from CLI notification
    /// Returns the updated list of sessions
    func processEvent(_ event: SessionEvent) -> [SessionState] {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) Processing event: session=\(event.sessionId.prefix(8), privacy: .public), event=\(event.eventName, privacy: .public)")

        // Cancel any pending done->idle timer for this session
        doneTimers[event.sessionId]?.cancel()
        doneTimers[event.sessionId] = nil

        // Check if this session was recently removed (race condition with background updates)
        if let removedAt = recentlyRemoved[event.sessionId] {
            if Date().timeIntervalSince(removedAt) < removalBlockDuration {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Ignoring event for recently-removed session \(event.sessionId.prefix(8), privacy: .public)")
                return store.activeSessions
            }
            // Removal block expired, allow re-creation
            recentlyRemoved.removeValue(forKey: event.sessionId)
        }

        // Determine the new status
        let status = determineStatus(for: event.eventName, notificationType: event.notificationType)

        // Update or create the session
        if var session = store.sessions[event.sessionId] {
            updateExistingSession(&session, with: event, status: status)
            store.sessions[event.sessionId] = session
        } else {
            let session = createNewSession(from: event, status: status)
            store.sessions[event.sessionId] = session
        }

        store.lastUpdated = Date()

        let processTime = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) Event processed (+\(String(format: "%.1f", processTime), privacy: .public)ms)")

        // If status is done, schedule transition to idle
        if status == .done {
            scheduleDoneToIdle(sessionId: event.sessionId)
        }

        return store.activeSessions
    }

    /// Handle session end (removal)
    /// Returns the updated list of sessions
    func removeSession(sessionId: String) -> [SessionState] {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) Removing session: \(sessionId.prefix(8), privacy: .public)")

        // Cancel any pending timer
        doneTimers[sessionId]?.cancel()
        doneTimers[sessionId] = nil

        store.sessions.removeValue(forKey: sessionId)
        store.lastUpdated = Date()

        // Track removal to prevent race condition with background updates
        recentlyRemoved[sessionId] = Date()
        cleanupRecentlyRemoved()

        let processTime = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) Session removed (+\(String(format: "%.1f", processTime), privacy: .public)ms)")

        return store.activeSessions
    }

    /// Get all current sessions
    func getAllSessions() -> [SessionState] {
        store.activeSessions
    }

    /// Set a callback to be invoked when sessions change (from internal state changes like done->idle)
    /// The callback will be called on the actor's context
    private var changeCallback: (([SessionState]) -> Void)?

    func setChangeCallback(_ callback: @escaping @Sendable ([SessionState]) -> Void) {
        self.changeCallback = callback
    }

    // MARK: - Private Helpers

    private func updateExistingSession(_ session: inout SessionState, with event: SessionEvent, status: SessionStatus) {
        session.status = status
        session.lastUpdated = Date()
        session.lastEventName = event.eventName
        if !event.workingDirectory.isEmpty {
            session.workingDirectory = event.workingDirectory
        }
        // Update optional fields if provided (keep existing if nil)
        if let tty = event.tty {
            session.tty = tty
        }
        if let bundleId = event.bundleId {
            session.bundleId = bundleId
        }
        if let summary = event.summary {
            session.summary = summary
        }
        if let gitBranch = event.gitBranch {
            session.gitBranch = gitBranch
        }
    }

    private func createNewSession(from event: SessionEvent, status: SessionStatus) -> SessionState {
        SessionState(
            id: event.sessionId,
            status: status,
            workingDirectory: event.workingDirectory,
            lastUpdated: Date(),
            lastEventName: event.eventName,
            tty: event.tty,
            bundleId: event.bundleId,
            summary: event.summary,
            gitBranch: event.gitBranch
        )
    }

    private func determineStatus(for eventName: String, notificationType: String?) -> SessionStatus {
        switch eventName {
        case "SessionStart":
            return .idle
        case "UserPromptSubmit":
            return .working
        case "Stop":
            return .done
        case "Notification":
            return determineNotificationStatus(notificationType)
        case "PermissionRequest":
            return .waitingForPermission
        case "PostToolUseFailure":
            return .error
        case "SubagentStart", "SubagentStop", "PreCompact":
            return .working
        default:
            return .working
        }
    }

    private func determineNotificationStatus(_ notificationType: String?) -> SessionStatus {
        switch notificationType {
        case "permission_prompt":
            return .waitingForPermission
        case "idle_prompt":
            return .idle
        case "elicitation_dialog":
            return .waitingForInput
        case "auth_success":
            return .working
        default:
            return .waitingForInput
        }
    }

    private func scheduleDoneToIdle(sessionId: String) {
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AgentSpritesConstants.doneToIdleDelay * 1_000_000_000))

            guard !Task.isCancelled else { return }
            await self?.transitionToIdle(sessionId: sessionId)
        }
        doneTimers[sessionId] = task
    }

    private func transitionToIdle(sessionId: String) {
        if var session = store.sessions[sessionId], session.status == .done {
            session.status = .idle
            session.lastUpdated = Date()
            store.sessions[sessionId] = session
            store.lastUpdated = Date()

            // Notify via callback
            changeCallback?(store.activeSessions)
        }
    }

    /// Clean up old entries from recentlyRemoved to prevent memory growth
    private func cleanupRecentlyRemoved() {
        let now = Date()
        recentlyRemoved = recentlyRemoved.filter { _, removedAt in
            now.timeIntervalSince(removedAt) < removalBlockDuration
        }
    }
}
