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
    @StateObject private var appState = AppState()
    @StateObject private var viewModel = SessionViewModel()
    @StateObject private var spriteCoordinator = SpriteCoordinator()
    @StateObject private var updateChecker = UpdateChecker()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                viewModel: viewModel,
                spriteCoordinator: spriteCoordinator,
                appState: appState,
                updateChecker: updateChecker
            )
        } label: {
            Image(nsImage: MenuBarIcon.makeImage())
        }
        .menuBarExtraStyle(.window)
        .onChange(of: viewModel.sessions) { newSessions in
            spriteCoordinator.updateSessions(newSessions)
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
        installBundledCharacterPacks()
        checkHookStatus()
    }

    /// Install bundled character packs to Application Support if not already present
    private func installBundledCharacterPacks() {
        guard let bundlePath = Bundle.main.resourcePath else {
            logger.debug("No bundle resource path found")
            return
        }

        let bundledPacksPath = URL(fileURLWithPath: bundlePath).appendingPathComponent("CharacterPacks")
        let destinationPath = AgentSpritesConstants.charactersDirectory

        // Check if bundled packs exist
        guard FileManager.default.fileExists(atPath: bundledPacksPath.path) else {
            logger.debug("No bundled character packs found")
            return
        }

        // Create Characters directory if needed
        do {
            try FileManager.default.createDirectory(at: destinationPath, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create Characters directory: \(error.localizedDescription, privacy: .public)")
            return
        }

        // Copy each bundled pack if it doesn't already exist
        guard let bundledPacks = try? FileManager.default.contentsOfDirectory(atPath: bundledPacksPath.path) else {
            return
        }

        for packName in bundledPacks {
            let sourcePack = bundledPacksPath.appendingPathComponent(packName)
            let destPack = destinationPath.appendingPathComponent(packName)

            // Skip if already installed
            if FileManager.default.fileExists(atPath: destPack.path) {
                logger.debug("Pack '\(packName, privacy: .public)' already installed, skipping")
                continue
            }

            do {
                try FileManager.default.copyItem(at: sourcePack, to: destPack)
                logger.info("Installed bundled character pack: \(packName, privacy: .public)")
            } catch {
                logger.error("Failed to install pack '\(packName, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            }
        }
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
                Task { @MainActor [weak self] in
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
            // Extract userInfo before entering async context (Notification is not Sendable)
            let userInfo = notification.userInfo
            Task { @MainActor [weak self] in
                self?.handleSessionEvent(userInfo: userInfo)
            }
        }

        // Listen for session end notifications from CLI
        endObserver = DistributedNotificationCenter.default().addObserver(
            forName: AgentSpritesConstants.sessionEndNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            // Extract userInfo before entering async context (Notification is not Sendable)
            let userInfo = notification.userInfo
            Task { @MainActor [weak self] in
                self?.handleSessionEnd(userInfo: userInfo)
            }
        }
    }

    private func handleSessionEvent(userInfo: [AnyHashable: Any]?) {
        let startTime = Date()
        logger.info("[TIMING] \(timestamp(), privacy: .public) App received session event notification")

        guard let userInfo,
              let eventJSON = userInfo["eventJSON"] as? String,
              let event = SessionEvent.fromJSONString(eventJSON) else {
            logger.warning("Failed to parse session event from notification")
            return
        }

        let parseTime = Date().timeIntervalSince(startTime) * 1000
        logger.info("[TIMING] \(timestamp(), privacy: .public) Event parsed (+\(String(format: "%.1f", parseTime), privacy: .public)ms), processing...")

        Task {
            await sessionManager.processEvent(event)
        }
    }

    private func handleSessionEnd(userInfo: [AnyHashable: Any]?) {
        logger.info("[TIMING] \(timestamp(), privacy: .public) App received session end notification")

        guard let userInfo,
              let sessionId = userInfo["sessionId"] as? String else {
            logger.warning("Failed to parse session ID from end notification")
            return
        }

        Task {
            await sessionManager.removeSession(sessionId: sessionId)
        }
    }

    /// Focus the terminal window for the given session
    func focusSession(_ session: SessionState) {
        logger.debug("focusSession called for: \(session.displayName)")
        Task {
            await terminalFocuser.focusSession(session)
        }
    }

    /// Manually close/remove a session from the UI
    func closeSession(_ session: SessionState) {
        logger.info("Manually closing session: \(session.id.prefix(8), privacy: .public)")
        Task {
            await sessionManager.removeSession(sessionId: session.id)
        }
    }
}
