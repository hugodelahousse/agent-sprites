import AppKit
import ApplicationServices
import os

// Top-level C callback for AXObserver — fires on main CFRunLoop
private func axObserverCallback(
    _: AXObserver,
    _: AXUIElement,
    _: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let watcher = Unmanaged<AccessibilityWindowWatcher>.fromOpaque(refcon).takeUnretainedValue()
    watcher.handleEvent()
}

/// Watches window changes via AXObserver for immediate notification of moves, resizes, etc.
/// Falls back gracefully when accessibility permission is not granted.
@MainActor
final class AccessibilityWindowWatcher {
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "AccessibilityWindowWatcher")

    /// Called (debounced) when any observed window changes
    var onWindowsChanged: (() -> Void)?

    private var observers: [pid_t: AXObserver] = [:]
    private var isRunning = false
    private var debounceTask: Task<Void, Never>?
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let notifications: [String] = [
        kAXWindowMovedNotification as String,
        kAXWindowResizedNotification as String,
        kAXWindowCreatedNotification as String,
        kAXUIElementDestroyedNotification as String,
        kAXWindowMiniaturizedNotification as String,
        kAXWindowDeminiaturizedNotification as String,
        kAXFocusedWindowChangedNotification as String,
    ]

    /// Whether accessibility access is currently available
    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    func start() {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else {
            logger.info("Accessibility not granted, skipping AXObserver setup")
            return
        }

        isRunning = true
        logger.info("Starting AXObserver-based window watching")

        // Register for all current GUI apps
        let ourPid = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if app.processIdentifier != ourPid {
                registerObserver(for: app.processIdentifier)
            }
        }

        // Watch for app launches and terminations
        let workspace = NSWorkspace.shared.notificationCenter

        let launchObserver = workspace.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.activationPolicy == .regular,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in
                self?.registerObserver(for: app.processIdentifier)
            }
        }

        let terminateObserver = workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor in
                self?.unregisterObserver(for: app.processIdentifier)
            }
        }

        workspaceObservers = [launchObserver, terminateObserver]
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        debounceTask?.cancel()
        debounceTask = nil

        for (pid, _) in observers {
            unregisterObserver(for: pid)
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
        workspaceObservers = []

        logger.info("Stopped AXObserver-based window watching")
    }

    // MARK: - Event Handling

    /// Called from the C callback — coalesces via 50ms debounce.
    /// Safe to call from main run loop (AXObserver delivers on main CFRunLoop).
    nonisolated func handleEvent() {
        MainActor.assumeIsolated {
            debounceTask?.cancel()
            debounceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                guard !Task.isCancelled else { return }
                self?.onWindowsChanged?()
            }
        }
    }

    // MARK: - Observer Management

    private func registerObserver(for pid: pid_t) {
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let result = AXObserverCreate(pid, axObserverCallback, &observer)
        guard result == .success, let observer else {
            // Not all apps support accessibility — this is expected
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        for notification in Self.notifications {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        observers[pid] = observer
    }

    private func unregisterObserver(for pid: pid_t) {
        guard let observer = observers.removeValue(forKey: pid) else { return }

        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )
    }
}
