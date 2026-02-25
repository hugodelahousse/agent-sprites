import SwiftUI
import AgentSpritesCore
import os.log

@main
struct AgentSpritesApp: App {
    @StateObject private var viewModel = SessionViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            Label("AgentSprites", systemImage: viewModel.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
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
    private let logger = Logger(subsystem: "com.agentsprites", category: "SessionViewModel")

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
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    await self?.setupConnection()
                }
            }
        }

        connection?.resume()

        // Initial fetch
        fetchSessions()
    }

    private func observeNotifications() {
        // Listen for distributed notifications from daemon
        notificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.fetchSessions()
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
