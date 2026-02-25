import Foundation
import AgentSpritesCore

/// CLI tool called by Claude Code hooks
/// Reads hook event JSON from stdin and forwards to the daemon via XPC

// MARK: - TTY and BundleID Resolution

/// Resolve the TTY device for the terminal session by walking the process tree
func resolveSessionTTY() -> String? {
    var pid = getppid()
    var highestTTY: String?

    while pid > 1 {
        // Get TTY for this process
        let ttyTask = Process()
        ttyTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        ttyTask.arguments = ["-p", "\(pid)", "-o", "tty="]

        let ttyPipe = Pipe()
        ttyTask.standardOutput = ttyPipe
        ttyTask.standardError = FileHandle.nullDevice

        do {
            try ttyTask.run()
            ttyTask.waitUntilExit()

            let ttyData = ttyPipe.fileHandleForReading.readDataToEndOfFile()
            let tty = String(data: ttyData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let tty = tty, !tty.isEmpty, tty != "??" {
                highestTTY = "/dev/\(tty)"
            }
        } catch {
            break
        }

        // Get parent PID
        let ppidTask = Process()
        ppidTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        ppidTask.arguments = ["-p", "\(pid)", "-o", "ppid="]

        let ppidPipe = Pipe()
        ppidTask.standardOutput = ppidPipe
        ppidTask.standardError = FileHandle.nullDevice

        do {
            try ppidTask.run()
            ppidTask.waitUntilExit()

            let ppidData = ppidPipe.fileHandleForReading.readDataToEndOfFile()
            if let ppidStr = String(data: ppidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parentPid = pid_t(ppidStr) {
                pid = parentPid
            } else {
                break
            }
        } catch {
            break
        }
    }

    return highestTTY
}

/// Resolve the bundle ID of the parent GUI application
func resolveParentBundleId() -> String? {
    var pid = getppid()

    while pid > 1 {
        // Get the executable path for this process
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "command="]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let execPath = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                // Check if this is an app bundle (contains .app/)
                if let appRange = execPath.range(of: ".app/") {
                    let appPath = String(execPath[..<appRange.upperBound].dropLast(1)) // Remove trailing /

                    // Read bundle ID from Info.plist
                    let plistPath = appPath + "/Contents/Info.plist"
                    if let plistData = FileManager.default.contents(atPath: plistPath),
                       let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
                       let bundleId = plist["CFBundleIdentifier"] as? String {
                        return bundleId
                    }
                }
            }
        } catch {
            // Continue to parent
        }

        // Get parent PID
        let ppidTask = Process()
        ppidTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        ppidTask.arguments = ["-p", "\(pid)", "-o", "ppid="]

        let ppidPipe = Pipe()
        ppidTask.standardOutput = ppidPipe
        ppidTask.standardError = FileHandle.nullDevice

        do {
            try ppidTask.run()
            ppidTask.waitUntilExit()

            let ppidData = ppidPipe.fileHandleForReading.readDataToEndOfFile()
            if let ppidStr = String(data: ppidData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               let parentPid = pid_t(ppidStr) {
                pid = parentPid
            } else {
                break
            }
        } catch {
            break
        }
    }

    return nil
}

// MARK: - Main

// Read JSON from stdin
let inputData = FileHandle.standardInput.readDataToEndOfFile()

guard !inputData.isEmpty else {
    fputs("Error: No input received on stdin\n", stderr)
    exit(1)
}

// Parse the hook event
let hookEvent: HookEvent
do {
    hookEvent = try HookEvent.parse(from: inputData)
} catch {
    fputs("Error parsing hook event: \(error.localizedDescription)\n", stderr)
    exit(1)
}

// Connect to daemon via XPC
let connection = NSXPCConnection(machServiceName: AgentSpritesConstants.xpcServiceName, options: [])
connection.remoteObjectInterface = createDaemonInterface()

connection.interruptionHandler = {
    fputs("XPC connection interrupted\n", stderr)
}

connection.invalidationHandler = {
    fputs("XPC connection invalidated\n", stderr)
}

connection.resume()

// Get proxy to daemon
let daemon = connection.remoteObjectProxyWithErrorHandler { error in
    fputs("XPC error: \(error.localizedDescription)\n", stderr)
    exit(1)
} as? AgentSpritesDaemonProtocol

guard let daemon = daemon else {
    fputs("Error: Could not get daemon proxy\n", stderr)
    exit(1)
}

// Resolve TTY and bundle ID for terminal focusing
let tty = resolveSessionTTY()
let bundleId = resolveParentBundleId()

// Use a semaphore to wait for async XPC call
let semaphore = DispatchSemaphore(value: 0)
var success = false

// Send update to daemon
daemon.updateSession(
    sessionId: hookEvent.sessionId,
    eventName: hookEvent.hookEventName,
    workingDirectory: hookEvent.cwd,
    tty: tty,
    bundleId: bundleId
) { result in
    success = result
    semaphore.signal()
}

// Wait for response with timeout
let timeout = DispatchTime.now() + .seconds(4)
if semaphore.wait(timeout: timeout) == .timedOut {
    fputs("Error: XPC call timed out\n", stderr)
    connection.invalidate()
    exit(1)
}

connection.invalidate()

if !success {
    fputs("Warning: Daemon returned failure for session update\n", stderr)
}

exit(0)
