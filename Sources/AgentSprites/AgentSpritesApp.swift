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
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel, blobCoordinator: blobCoordinator, appState: appState)
        } label: {
            Label("AgentSprites", systemImage: viewModel.menuBarIcon)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: viewModel.sessions) { newSessions in
            blobCoordinator.updateSessions(newSessions)
        }
    }
}

/// Type of hook prompt to show
enum HookPromptType: Equatable {
    case install
    case replace(existingPath: String)
}

/// App-wide state for things like hook installation status
@MainActor
final class AppState: ObservableObject {
    @Published var hooksInstalled: Bool = false
    @Published var hookPromptType: HookPromptType?

    var showingHookPrompt: Bool {
        hookPromptType != nil
    }

    private let logger = Logger(subsystem: "com.agentsprites.app", category: "AppState")

    init() {
        checkHookStatus()
    }

    func checkHookStatus() {
        let status = HookInstaller.checkExistingHooks()
        logger.info("Hook status: \(String(describing: status), privacy: .public)")

        switch status {
        case .currentApp:
            hooksInstalled = true
            hookPromptType = nil

        case .none:
            hooksInstalled = false
            // Show install prompt if CLI is bundled
            if HookInstaller.bundledCLIPath != nil {
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    hookPromptType = .install
                }
            }

        case .differentApp(let path):
            hooksInstalled = false
            // Show replace prompt
            Task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                hookPromptType = .replace(existingPath: path)
            }
        }
    }

    func installHooks() {
        if HookInstaller.installHooks() {
            hooksInstalled = true
            hookPromptType = nil
            logger.info("Hooks installed successfully via prompt")
        } else {
            logger.error("Failed to install hooks via prompt")
        }
    }

    func skipHookInstall() {
        hookPromptType = nil
    }
}

/// View model managing session state via distributed notifications from CLI
@MainActor
final class SessionViewModel: ObservableObject {
    @Published var sessions: [SessionState] = []
    @Published var isConnected = true  // Always "connected" since we use notifications

    private let sessionManager = SessionManager()
    private var eventObserver: NSObjectProtocol?
    private var endObserver: NSObjectProtocol?
    private let terminalFocuser = TerminalFocuser()
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "SessionViewModel")

    var menuBarIcon: String {
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
        setupSessionManager()
        observeNotifications()
    }

    deinit {
        if let observer = eventObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        if let observer = endObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func setupSessionManager() {
        // Set up callback for internal state changes (like done->idle transitions)
        Task {
            await sessionManager.setChangeCallback { [weak self] sessions in
                Task { @MainActor in
                    self?.sessions = sessions
                }
            }
        }
    }

    private func observeNotifications() {
        // Listen for session events from CLI
        eventObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionEventNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleSessionEvent(notification)
            }
        }

        // Listen for session end notifications from CLI
        endObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionEndNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            Task { @MainActor in
                self.handleSessionEnd(notification)
            }
        }
    }

    private func handleSessionEvent(_ notification: Notification) {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) App received session event notification")

        guard let userInfo = notification.userInfo,
              let eventJSON = userInfo["eventJSON"] as? String,
              let event = SessionEvent.fromJSONString(eventJSON) else {
            logger.warning("Failed to parse session event from notification")
            return
        }

        let parseTime = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) Event parsed (+\(String(format: "%.1f", parseTime), privacy: .public)ms), processing...")

        Task {
            let updatedSessions = await sessionManager.processEvent(event)
            self.sessions = updatedSessions
        }
    }

    private func handleSessionEnd(_ notification: Notification) {
        logger.info("[TIMING] \(timestamp(), privacy: .public) App received session end notification")

        guard let userInfo = notification.userInfo,
              let sessionId = userInfo["sessionId"] as? String else {
            logger.warning("Failed to parse session ID from end notification")
            return
        }

        Task {
            let updatedSessions = await sessionManager.removeSession(sessionId: sessionId)
            self.sessions = updatedSessions
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
