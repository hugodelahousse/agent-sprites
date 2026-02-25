import Foundation
import AgentSpritesCore
import os

/// CLI tool called by Claude Code hooks
/// Reads hook event JSON from stdin and forwards to the daemon via XPC

private let logger = Logger(subsystem: "com.agentsprites.cli", category: "main")

// MARK: - Session Metadata

/// Session entry from sessions-index.json
struct SessionIndexEntry: Codable {
    let sessionId: String
    let summary: String?
    let gitBranch: String?
    let firstPrompt: String?
}

/// Sessions index file structure
struct SessionsIndex: Codable {
    let entries: [SessionIndexEntry]
}

/// Transcript user message structure
struct TranscriptUserMessage: Codable {
    let type: String
    let message: MessageContent?
    let gitBranch: String?

    struct MessageContent: Codable {
        let content: String
    }
}

/// Extract first user message from transcript file as fallback summary
/// - Parameter transcriptPath: Path to the transcript .jsonl file
/// - Returns: Tuple of (firstPrompt truncated, gitBranch) if found
func extractFromTranscript(transcriptPath: String) -> (summary: String?, gitBranch: String?) {
    guard let fileHandle = FileHandle(forReadingAtPath: transcriptPath) else {
        logger.debug("Could not open transcript file")
        return (nil, nil)
    }
    defer { try? fileHandle.close() }

    // Read first 32KB to find the first user message (should be near the start)
    let data = fileHandle.readData(ofLength: 32 * 1024)
    guard let content = String(data: data, encoding: .utf8) else {
        return (nil, nil)
    }

    // Parse line by line (JSONL format)
    for line in content.components(separatedBy: .newlines) {
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8) else { continue }

        do {
            let entry = try JSONDecoder().decode(TranscriptUserMessage.self, from: lineData)
            if entry.type == "user", let messageContent = entry.message?.content {
                // Truncate long prompts to make a reasonable summary
                let maxLength = 80
                var summary = messageContent
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                if summary.count > maxLength {
                    summary = String(summary.prefix(maxLength)) + "…"
                }
                logger.debug("Extracted from transcript: summary=\(summary, privacy: .public), gitBranch=\(entry.gitBranch ?? "nil", privacy: .public)")
                return (summary, entry.gitBranch)
            }
        } catch {
            // Not a user message or different format, continue
            continue
        }
    }

    return (nil, nil)
}

/// Look up session metadata from sessions-index.json, falling back to transcript parsing
/// - Parameter transcriptPath: Path to the transcript file (e.g., ~/.claude/projects/.../session-id.jsonl)
/// - Parameter sessionId: The session ID to look up
/// - Returns: Tuple of (summary, gitBranch) if found
func lookupSessionMetadata(transcriptPath: String?, sessionId: String) -> (summary: String?, gitBranch: String?) {
    guard let transcriptPath = transcriptPath else {
        logger.debug("transcriptPath is nil")
        return (nil, nil)
    }

    // The sessions-index.json is in the same directory as the transcript
    let transcriptURL = URL(fileURLWithPath: transcriptPath)
    let projectDir = transcriptURL.deletingLastPathComponent()
    let indexPath = projectDir.appendingPathComponent("sessions-index.json")

    logger.debug("Looking for sessions-index.json at: \(indexPath.path, privacy: .public)")

    if let indexData = FileManager.default.contents(atPath: indexPath.path) {
        logger.debug("Found sessions-index.json, size: \(indexData.count) bytes")

        do {
            let index = try JSONDecoder().decode(SessionsIndex.self, from: indexData)
            logger.debug("Decoded \(index.entries.count) entries, looking for sessionId: \(sessionId, privacy: .public)")
            if let entry = index.entries.first(where: { $0.sessionId == sessionId }) {
                logger.debug("Found entry with summary: \(entry.summary ?? "nil", privacy: .public), gitBranch: \(entry.gitBranch ?? "nil", privacy: .public)")
                return (entry.summary, entry.gitBranch)
            } else {
                logger.debug("Session not in index, falling back to transcript parsing")
            }
        } catch {
            logger.error("Failed to decode sessions-index.json: \(error, privacy: .public)")
        }
    }

    // Fallback: parse transcript file directly for active sessions
    return extractFromTranscript(transcriptPath: transcriptPath)
}

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

// Look up session metadata from sessions-index.json
let (summary, gitBranch) = lookupSessionMetadata(
    transcriptPath: hookEvent.transcriptPath,
    sessionId: hookEvent.sessionId
)

logger.info("Sending to daemon: session=\(hookEvent.sessionId, privacy: .public), event=\(hookEvent.hookEventName, privacy: .public), summary=\(summary ?? "nil", privacy: .public), gitBranch=\(gitBranch ?? "nil", privacy: .public)")

// Use a semaphore to wait for async XPC call
let semaphore = DispatchSemaphore(value: 0)
var success = false

// Send update to daemon
daemon.updateSession(
    sessionId: hookEvent.sessionId,
    eventName: hookEvent.hookEventName,
    workingDirectory: hookEvent.cwd,
    tty: tty,
    bundleId: bundleId,
    summary: summary,
    gitBranch: gitBranch
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
