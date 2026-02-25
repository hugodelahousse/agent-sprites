import Foundation
import AgentSpritesCore

/// Manages session states in memory with notifications
actor SessionManager {
    private var store = SessionStore()
    private var doneTimers: [String: Task<Void, Never>] = [:]

    /// Update a session based on a hook event
    func updateSession(sessionId: String, eventName: String, workingDirectory: String, tty: String?, bundleId: String?, summary: String?, gitBranch: String?) -> Bool {
        // Cancel any pending done->idle timer for this session
        doneTimers[sessionId]?.cancel()
        doneTimers[sessionId] = nil

        // Handle session end - remove the session
        if eventName == "SessionEnd" {
            store.sessions.removeValue(forKey: sessionId)
            store.lastUpdated = Date()
            notifyUpdate()
            return true
        }

        // Determine the new status
        let status = determineStatus(for: eventName)

        // Update or create the session
        if var session = store.sessions[sessionId] {
            session.status = status
            session.lastUpdated = Date()
            session.lastEventName = eventName
            if !workingDirectory.isEmpty {
                session.workingDirectory = workingDirectory
            }
            // Update optional fields if provided (keep existing if nil)
            if let tty = tty {
                session.tty = tty
            }
            if let bundleId = bundleId {
                session.bundleId = bundleId
            }
            if let summary = summary {
                session.summary = summary
            }
            if let gitBranch = gitBranch {
                session.gitBranch = gitBranch
            }
            store.sessions[sessionId] = session
        } else {
            let session = SessionState(
                id: sessionId,
                status: status,
                workingDirectory: workingDirectory,
                lastUpdated: Date(),
                lastEventName: eventName,
                tty: tty,
                bundleId: bundleId,
                summary: summary,
                gitBranch: gitBranch
            )
            store.sessions[sessionId] = session
        }

        store.lastUpdated = Date()
        notifyUpdate()

        // If status is done, schedule transition to idle
        if status == .done {
            scheduleDoneToIdle(sessionId: sessionId)
        }

        return true
    }

    /// Get all current sessions
    func getAllSessions() -> SessionStore {
        return store
    }

    /// Get sessions as JSON data
    func getSessionsData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try? encoder.encode(store)
    }

    // MARK: - Private

    private func determineStatus(for eventName: String) -> SessionStatus {
        switch eventName {
        case "SessionStart":
            return .idle
        case "UserPromptSubmit":
            return .working
        case "Stop":
            return .done
        case "Notification":
            return .waitingForInput
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
            notifyUpdate()
        }
    }

    private func notifyUpdate() {
        DistributedNotificationCenter.default().postNotificationName(
            AgentSpritesConstants.sessionsDidChangeNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }
}
