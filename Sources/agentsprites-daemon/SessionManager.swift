import Foundation
import AgentSpritesCore
import os.log

private let logger = Logger(subsystem: "com.agentsprites.daemon", category: "SessionManager")

private func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

/// Manages session states in memory with notifications
actor SessionManager {
    private var store = SessionStore()
    private var doneTimers: [String: Task<Void, Never>] = [:]
    /// Recently removed session IDs with removal timestamp (prevents race with background updates)
    private var recentlyRemoved: [String: Date] = [:]
    /// How long to block re-creation of removed sessions
    private let removalBlockDuration: TimeInterval = 10.0

    /// Update a session based on a hook event
    func updateSession(_ request: SessionUpdateRequest) -> Bool {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) Daemon received update: session=\(request.sessionId.prefix(8), privacy: .public), event=\(request.eventName, privacy: .public)")
        // Cancel any pending done->idle timer for this session
        doneTimers[request.sessionId]?.cancel()
        doneTimers[request.sessionId] = nil

        // Handle session end - remove the session
        if request.eventName == "SessionEnd" {
            store.sessions.removeValue(forKey: request.sessionId)
            store.lastUpdated = Date()
            // Track removal to prevent race condition with background updates
            recentlyRemoved[request.sessionId] = Date()
            cleanupRecentlyRemoved()
            let processTime = Date().timeIntervalSince(startTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Daemon processed SessionEnd (+\(String(format: "%.1f", processTime), privacy: .public)ms), posting notification")
            notifySessionRemoved(sessionId: request.sessionId)
            return true
        }

        // Check if this session was recently removed (race condition with background updates)
        if let removedAt = recentlyRemoved[request.sessionId] {
            if Date().timeIntervalSince(removedAt) < removalBlockDuration {
                logger.info("[TIMING] \(timestamp(), privacy: .public) Ignoring update for recently-removed session \(request.sessionId.prefix(8), privacy: .public)")
                return true
            }
            // Removal block expired, allow re-creation
            recentlyRemoved.removeValue(forKey: request.sessionId)
        }

        // Determine the new status
        let status = determineStatus(for: request.eventName, notificationType: request.notificationType)

        // Update or create the session
        if var session = store.sessions[request.sessionId] {
            updateExistingSession(&session, with: request, status: status)
            store.sessions[request.sessionId] = session
        } else {
            let session = createNewSession(from: request, status: status)
            store.sessions[request.sessionId] = session
        }

        store.lastUpdated = Date()
        let updatedSession = store.sessions[request.sessionId]

        let processTime = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) Daemon processed update (+\(String(format: "%.1f", processTime), privacy: .public)ms), posting notification")

        notifyUpdate(session: updatedSession)

        // If status is done, schedule transition to idle
        if status == .done {
            scheduleDoneToIdle(sessionId: request.sessionId)
        }

        return true
    }

    /// Get all current sessions
    func getAllSessions() -> SessionStore {
        store
    }

    /// Get sessions as JSON data
    func getSessionsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(store)
    }

    // MARK: - Private Helpers

    private func updateExistingSession(_ session: inout SessionState, with request: SessionUpdateRequest, status: SessionStatus) {
        session.status = status
        session.lastUpdated = Date()
        session.lastEventName = request.eventName
        if !request.workingDirectory.isEmpty {
            session.workingDirectory = request.workingDirectory
        }
        // Update optional fields if provided (keep existing if nil)
        if let tty = request.tty {
            session.tty = tty
        }
        if let bundleId = request.bundleId {
            session.bundleId = bundleId
        }
        if let summary = request.summary {
            session.summary = summary
        }
        if let gitBranch = request.gitBranch {
            session.gitBranch = gitBranch
        }
    }

    private func createNewSession(from request: SessionUpdateRequest, status: SessionStatus) -> SessionState {
        SessionState(
            id: request.sessionId,
            status: status,
            workingDirectory: request.workingDirectory,
            lastUpdated: Date(),
            lastEventName: request.eventName,
            tty: request.tty,
            bundleId: request.bundleId,
            summary: request.summary,
            gitBranch: request.gitBranch
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
        case "SubagentStart", "PreCompact":
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
            notifyUpdate(session: session)
        }
    }

    private func notifyUpdate(session: SessionState? = nil) {
        var userInfo: [String: Any]?

        // Include session data in notification to avoid redundant XPC round-trip
        if let session {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(session),
               let json = String(data: data, encoding: .utf8) {
                userInfo = ["sessionJSON": json]
            }
        }

        DistributedNotificationCenter.default().postNotificationName(
            AgentSpritesConstants.sessionsDidChangeNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    private func notifySessionRemoved(sessionId: String) {
        let userInfo: [String: Any] = ["removedSessionId": sessionId]
        DistributedNotificationCenter.default().postNotificationName(
            AgentSpritesConstants.sessionsDidChangeNotification,
            object: nil,
            userInfo: userInfo,
            deliverImmediately: true
        )
    }

    /// Clean up old entries from recentlyRemoved to prevent memory growth
    private func cleanupRecentlyRemoved() {
        let now = Date()
        recentlyRemoved = recentlyRemoved.filter { _, removedAt in
            now.timeIntervalSince(removedAt) < removalBlockDuration
        }
    }
}
