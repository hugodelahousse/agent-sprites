import AppKit
import AgentSpritesCore
import os.log

/// Service for focusing terminal windows based on session information
actor TerminalFocuser {
    private let logger = Logger(subsystem: "com.agentsprites.app", category: "TerminalFocuser")

    /// Focus the terminal session associated with the given session state
    func focusSession(_ session: SessionState) async {
        logger.debug("focusSession called: bundleId=\(session.bundleId ?? "nil", privacy: .public), tty=\(session.tty ?? "nil", privacy: .public)")
        switch session.bundleId {
        case "com.googlecode.iterm2":
            logger.debug("Routing to focusITerm2")
            await focusITerm2(tty: session.tty)
        default:
            logger.debug("Routing to activateApp")
            await activateApp(bundleId: session.bundleId)
        }
    }

    // MARK: - Private

    /// Focus iTerm2 by finding the tab/pane with the matching TTY
    private func focusITerm2(tty: String?) async {
        logger.debug("focusITerm2: tty=\(tty ?? "nil", privacy: .public)")
        guard let tty = tty else {
            logger.debug("No TTY, falling back to activateApp")
            await activateApp(bundleId: "com.googlecode.iterm2")
            return
        }

        // Simple AppleScript: find session by TTY, select it, activate iTerm2
        let script = """
        tell application "iTerm2"
            set targetTTY to "\(tty)"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if tty of s is targetTTY then
                                select t
                                select s
                                activate
                                return "found"
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
            activate
            return "not_found"
        end tell
        """

        logger.debug("Running AppleScript for TTY: \(tty, privacy: .public)")

        await MainActor.run {
            var error: NSDictionary?  // swiftlint:disable:this legacy_objc_type
            let appleScript = NSAppleScript(source: script)
            let result = appleScript?.executeAndReturnError(&error)

            let output = result?.stringValue ?? ""
            let errorDesc = error?[NSAppleScript.errorMessage] as? String ?? ""

            logger.debug("AppleScript result: \(output, privacy: .public), error: \(errorDesc, privacy: .public)")
        }
    }

    /// Activate an application by bundle ID using NSWorkspace
    private func activateApp(bundleId: String?) async {
        logger.debug("activateApp: bundleId=\(bundleId ?? "nil", privacy: .public)")
        guard let bundleId = bundleId else {
            logger.debug("No bundleId, returning")
            return
        }

        await MainActor.run {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            logger.debug("Found \(apps.count) running apps for \(bundleId, privacy: .public)")
            if let app = apps.first {
                let result = app.activate(options: [.activateIgnoringOtherApps])
                logger.debug("activate() returned: \(result)")
            }
        }
    }
}
