import SwiftUI
import AgentSpritesCore
import os.log

private func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

@main
struct AgentSpritesApp: App {
    @StateObject private var viewModel = SessionViewModel()
    @StateObject private var blobCoordinator = BlobCoordinator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel, blobCoordinator: blobCoordinator)
        } label: {
            Label("AgentSprites", systemImage: viewModel.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: viewModel.sessions) { newSessions in
            blobCoordinator.updateSessions(newSessions)
        }
    }
}

/// View model managing session state and XPC connection to daemon
@MainActor
final class SessionViewModel: ObservableObject {
    @Published var sessions: [SessionState] = []
    @Published var isConnected = false
    @Published var lastError: String?

    private var connection: NSXPCConnection?
    private var notificationObserver: NSObjectProtocol?
    private let terminalFocuser = TerminalFocuser()
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SessionViewModel")

    var menuBarIcon: String {
        if !isConnected {
            return "exclamationmark.circle"
        }

        let hasWorking = sessions.contains { $0.status == .working }
        let hasWaiting = sessions.contains { $0.status == .waitingForInput || $0.status == .waitingForPermission }
        let hasError = sessions.contains { $0.status == .error }

        if hasError || hasWaiting {
            return "person.crop.circle.badge.exclamationmark"
        } else if hasWorking {
            return "person.crop.circle.badge.clock"
        } else if !sessions.isEmpty {
            return "person.crop.circle"
        }
        return "person.crop.circle"
    }

    init() {
        setupConnection()
        observeNotifications()
    }

    deinit {
        if let observer = notificationObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        connection?.invalidate()
    }

    private func setupConnection() {
        connection = NSXPCConnection(machServiceName: AgentSpritesConstants.xpcServiceName, options: [])
        connection?.remoteObjectInterface = createDaemonInterface()

        connection?.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                self?.lastError = "Connection interrupted"
            }
        }

        connection?.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.isConnected = false
                // Try to reconnect after a delay
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.setupConnection()
            }
        }

        connection?.resume()

        // Initial fetch
        fetchSessions()
    }

    private var hookStartedObserver: NSObjectProtocol?

    private func observeNotifications() {
        // Listen for immediate hook started notification (direct from CLI, bypasses daemon)
        hookStartedObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.agentsprites.hookStarted"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.logger.info("[TIMING] \(timestamp(), privacy: .public) App received hookStarted notification")
        }

        // Listen for distributed notifications from daemon
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                self?.handleSessionNotification(notification)
            }
        }
    }

    private func handleSessionNotification(_ notification: Notification) {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) App received notification")

        guard let userInfo = notification.userInfo else {
            // No payload, fallback to full fetch
            logger.info("[TIMING] \(timestamp(), privacy: .public) No payload, falling back to fetchSessions")
            fetchSessions()
            return
        }

        isConnected = true
        lastError = nil

        // Handle session removal
        if let removedId = userInfo["removedSessionId"] as? String {
            sessions.removeAll { $0.id == removedId }
            let elapsed = Date().timeIntervalSince(startTime) * 1000
            logger.info("[TIMING] \(timestamp(), privacy: .public) Session removed (+\(String(format: "%.1f", elapsed), privacy: .public)ms)")
            return
        }

        // Try to extract session directly from notification payload (avoids XPC round-trip)
        if let sessionJSON = userInfo["sessionJSON"] as? String,
           let jsonData = sessionJSON.data(using: .utf8) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let session = try? decoder.decode(SessionState.self, from: jsonData) {
                updateSession(session)
                let elapsed = Date().timeIntervalSince(startTime) * 1000
                logger.info("[TIMING] \(timestamp(), privacy: .public) Session updated from payload (+\(String(format: "%.1f", elapsed), privacy: .public)ms)")
                return
            }
        }

        // Fallback to full fetch if payload invalid
        logger.info("[TIMING] \(timestamp(), privacy: .public) Invalid payload, falling back to fetchSessions")
        fetchSessions()
    }

    private func updateSession(_ session: SessionState) {
        // Update existing session or add new one
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
            sessions.sort { $0.lastUpdated > $1.lastUpdated }
        }
    }

    func fetchSessions() {
        let daemon = connection?.remoteObjectProxyWithErrorHandler { [weak self] error in
            Task { @MainActor in
                self?.isConnected = false
                self?.lastError = error.localizedDescription
            }
        } as? AgentSpritesDaemonProtocol

        daemon?.getAllSessions { [weak self] data in
            Task { @MainActor in
                guard let self = self, let data = data else {
                    self?.isConnected = false
                    return
                }

                self.isConnected = true
                self.lastError = nil

                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                if let store = try? decoder.decode(SessionStore.self, from: data) {
                    self.sessions = store.activeSessions
                }
            }
        }

        // Also ping to verify connection
        daemon?.ping { [weak self] alive in
            Task { @MainActor in
                self?.isConnected = alive
            }
        }
    }

    /// Focus the terminal window for the given session
    func focusSession(_ session: SessionState) {
        logger.debug("focusSession called for: \(session.displayName)")
        Task {
            await terminalFocuser.focusSession(session)
        }
    }
}
