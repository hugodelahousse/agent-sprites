import Foundation
import AgentSpritesCore
import os

/// CLI tool called by Claude Code hooks
/// Reads hook event JSON from stdin and sends to the app via Distributed Notifications

private let logger = Logger(subsystem: "com.agentsprites.cli", category: "main")

// MARK: - Process Tree Cache

/// Cache entry for TTY/BundleId lookup results
struct ProcessTreeCacheEntry: Codable {
    let tty: String?
    let bundleId: String?
    let timestamp: Date
}

/// File-based cache for TTY/BundleId lookups (survives CLI restarts)
enum ProcessTreeCache {
    private static let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("agentsprites-cache")
    private static let maxAge: TimeInterval = 3600 // 1 hour

    static func get(sessionId: String) -> ProcessTreeCacheEntry? {
        let path = cacheDir.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: path),
              let entry = try? JSONDecoder().decode(ProcessTreeCacheEntry.self, from: data) else {
            return nil
        }

        // Check if cache entry is still valid
        if Date().timeIntervalSince(entry.timestamp) > maxAge {
            try? FileManager.default.removeItem(at: path)
            return nil
        }

        return entry
    }

    static func set(sessionId: String, tty: String?, bundleId: String?) {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let entry = ProcessTreeCacheEntry(tty: tty, bundleId: bundleId, timestamp: Date())
        let path = cacheDir.appendingPathComponent("\(sessionId).json")
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: path)
        }
    }
}

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

/// Transcript entry structure for parsing various entry types
struct TranscriptEntry: Codable {
    let type: String
    let message: MessageContent?
    let gitBranch: String?
    let summary: String?  // Present when type == "summary"

    struct MessageContent: Codable {
        let content: String
    }
}

/// Extract session metadata from transcript file
/// Prioritizes the latest "summary" entry, falls back to first user message
/// - Parameter transcriptPath: Path to the transcript .jsonl file
/// - Returns: Tuple of (summary, gitBranch) if found
func extractFromTranscript(transcriptPath: String) -> (summary: String?, gitBranch: String?) {
    guard let data = FileManager.default.contents(atPath: transcriptPath),
          let content = String(data: data, encoding: .utf8) else {
        logger.debug("Could not read transcript file")
        return (nil, nil)
    }

    var latestSummary: String?
    var firstUserMessage: String?
    var gitBranch: String?

    // Parse line by line (JSONL format)
    for line in content.components(separatedBy: .newlines) {
        guard !line.isEmpty,
              let lineData = line.data(using: .utf8) else { continue }

        do {
            let entry = try JSONDecoder().decode(TranscriptEntry.self, from: lineData)

            // Capture gitBranch from any entry that has it
            if gitBranch == nil, let branch = entry.gitBranch {
                gitBranch = branch
            }

            // Look for summary entries (these are Claude-generated session titles)
            if entry.type == "summary", let summary = entry.summary {
                latestSummary = summary
                logger.debug("Found summary entry: \(summary, privacy: .public)")
            }

            // Capture first user message as fallback
            if firstUserMessage == nil,
               entry.type == "user",
               let messageContent = entry.message?.content {
                // Skip messages that look like system-injected content
                let trimmed = messageContent.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("<") {
                    let maxLength = 80
                    var msg = trimmed.replacingOccurrences(of: "\n", with: " ")
                    if msg.count > maxLength {
                        msg = String(msg.prefix(maxLength)) + "…"
                    }
                    firstUserMessage = msg
                }
            }
        } catch {
            continue
        }
    }

    // Prefer the Claude-generated summary, fall back to first user message
    let summary = latestSummary ?? firstUserMessage
    logger.debug("Extracted from transcript: summary=\(summary ?? "nil", privacy: .public), gitBranch=\(gitBranch ?? "nil", privacy: .public)")
    return (summary, gitBranch)
}

/// Look up session metadata, preferring the transcript for the latest summary
/// - Parameter transcriptPath: Path to the transcript file (e.g., ~/.claude/projects/.../session-id.jsonl)
/// - Parameter sessionId: The session ID to look up
/// - Returns: Tuple of (summary, gitBranch) if found
func lookupSessionMetadata(transcriptPath: String?, sessionId: String) -> (summary: String?, gitBranch: String?) {
    guard let transcriptPath = transcriptPath else {
        logger.debug("transcriptPath is nil")
        return (nil, nil)
    }

    // Always parse transcript first - it has the most recent summary for active sessions
    let (transcriptSummary, transcriptBranch) = extractFromTranscript(transcriptPath: transcriptPath)

    // If transcript has a summary, use it (latest is always preferred)
    if transcriptSummary != nil {
        logger.debug("Using transcript summary: \(transcriptSummary ?? "nil", privacy: .public)")
        return (transcriptSummary, transcriptBranch)
    }

    // Fallback to sessions-index.json if transcript has no summary
    let transcriptURL = URL(fileURLWithPath: transcriptPath)
    let projectDir = transcriptURL.deletingLastPathComponent()
    let indexPath = projectDir.appendingPathComponent("sessions-index.json")

    logger.debug("No transcript summary, checking sessions-index.json at: \(indexPath.path, privacy: .public)")

    if let indexData = FileManager.default.contents(atPath: indexPath.path) {
        do {
            let index = try JSONDecoder().decode(SessionsIndex.self, from: indexData)
            if let entry = index.entries.first(where: { $0.sessionId == sessionId }) {
                logger.debug("Found index entry with summary: \(entry.summary ?? "nil", privacy: .public)")
                // Use index summary, but prefer transcript's gitBranch if available
                return (entry.summary, transcriptBranch ?? entry.gitBranch)
            }
        } catch {
            logger.error("Failed to decode sessions-index.json: \(error, privacy: .public)")
        }
    }

    // Return whatever we got from the transcript (may have gitBranch even without summary)
    return (nil, transcriptBranch)
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

// MARK: - IPC

/// IPC provider for sending events to the app.
/// Uses DistributedNotificationCenter on macOS (reliable, no server needed),
/// with socket-based fallback available for cross-platform use.
#if canImport(AppKit)
private let ipcProvider: IPCProvider = {
    /// Dual IPC: post via both DistributedNotificationCenter (primary, reliable)
    /// and socket (secondary, cross-platform). App can listen on either.
    final class DualIPCProvider: IPCProvider, @unchecked Sendable {
        private let socketIPC = SocketIPCProvider()

        func postSessionEvent(_ event: SessionEvent) throws {
            // Primary: DistributedNotificationCenter (always works on macOS)
            guard let eventJSON = event.toJSONString() else { return }
            DistributedNotificationCenter.default().postNotificationName(
                AgentSpritesConstants.sessionEventNotification,
                object: nil,
                userInfo: ["eventJSON": eventJSON],
                deliverImmediately: true
            )
            // Secondary: also post via socket (for cross-platform testing)
            try? socketIPC.postSessionEvent(event)
        }

        func postSessionEnd(sessionId: String) throws {
            DistributedNotificationCenter.default().postNotificationName(
                AgentSpritesConstants.sessionEndNotification,
                object: nil,
                userInfo: ["sessionId": sessionId],
                deliverImmediately: true
            )
            try? socketIPC.postSessionEnd(sessionId: sessionId)
        }

        func observeEvents(
            onSessionEvent: @escaping @Sendable (SessionEvent) -> Void,
            onSessionEnd: @escaping @Sendable (String) -> Void
        ) {
            // CLI doesn't observe
        }

        func stopObserving() {}
    }
    return DualIPCProvider()
}()
#else
// Non-macOS: use socket IPC only
private let ipcProvider: IPCProvider = SocketIPCProvider()
#endif

/// Post a session event to the app
func postSessionEvent(_ event: SessionEvent) {
    do {
        try ipcProvider.postSessionEvent(event)
    } catch {
        logger.error("Failed to post session event: \(error.localizedDescription, privacy: .public)")
    }
}

/// Post a session end notification to the app
func postSessionEnd(sessionId: String) {
    do {
        try ipcProvider.postSessionEnd(sessionId: sessionId)
    } catch {
        logger.error("Failed to post session end: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Background Mode

/// Run slow lookups and send follow-up update (called in background subprocess)
func runBackgroundUpdate(hookEventJSON: String) {
    guard let jsonData = hookEventJSON.data(using: .utf8),
          let hookEvent = try? HookEvent.parse(from: jsonData) else {
        logger.error("Background: Failed to parse hook event")
        return
    }

    // Check if we need to resolve process tree
    let cachedEntry = ProcessTreeCache.get(sessionId: hookEvent.sessionId)
    var tty = cachedEntry?.tty
    var bundleId = cachedEntry?.bundleId

    if cachedEntry == nil {
        // Resolve TTY and bundle ID (slow - involves spawning ps processes)
        tty = resolveSessionTTY()
        bundleId = resolveParentBundleId()
        ProcessTreeCache.set(sessionId: hookEvent.sessionId, tty: tty, bundleId: bundleId)
    }

    // Look up session metadata
    let (summary, gitBranch) = lookupSessionMetadata(
        transcriptPath: hookEvent.transcriptPath,
        sessionId: hookEvent.sessionId
    )

    logger.info("Background: sending metadata update")

    let event = SessionEvent(
        from: hookEvent,
        tty: tty,
        bundleId: bundleId,
        summary: summary,
        gitBranch: gitBranch,
        isMetadataUpdate: true  // Don't trigger state transitions
    )
    postSessionEvent(event)
}

/// Spawn background process to do slow lookups
func spawnBackgroundUpdate(hookEventJSON: String, executablePath: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = ["--background", hookEventJSON]

    // Detach from parent - don't wait for completion
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        // Don't wait - let it run in background
    } catch {
        logger.warning("Failed to spawn background process: \(error.localizedDescription, privacy: .public)")
    }
}

// MARK: - Timing Helpers

func timestamp() -> String {
    let now = Date()
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: now)
}

// MARK: - Main

let args = CommandLine.arguments
let cliStartTime = Date()

// Check for background mode (called by ourselves for slow lookups)
if args.count >= 3 && args[1] == "--background" {
    logger.info("[TIMING] \(timestamp(), privacy: .public) Background process started")
    runBackgroundUpdate(hookEventJSON: args[2])
    exit(0)
}

logger.info("[TIMING] \(timestamp(), privacy: .public) CLI started")

// Read JSON from stdin
let inputData = FileHandle.standardInput.readDataToEndOfFile()
let stdinReadTime = Date()
logger.info("[TIMING] \(timestamp(), privacy: .public) stdin read complete (+\(String(format: "%.1f", stdinReadTime.timeIntervalSince(cliStartTime) * 1000), privacy: .public)ms)")

guard !inputData.isEmpty else {
    logger.error("[TIMING] \(timestamp(), privacy: .public) Error: empty stdin")
    fputs("Error: No input received on stdin\n", stderr)
    exit(1)
}

// Parse the hook event
let hookEvent: HookEvent
do {
    hookEvent = try HookEvent.parse(from: inputData)
} catch {
    let rawString = String(data: inputData, encoding: .utf8) ?? "(non-utf8 data)"
    let preview = String(rawString.prefix(500))
    logger.error("[TIMING] \(timestamp(), privacy: .public) Error parsing JSON: \(error.localizedDescription, privacy: .public) - data preview: \(preview, privacy: .public)")
    fputs("Error parsing hook event: \(error.localizedDescription)\n", stderr)
    exit(1)
}

let parseTime = Date()
logger.info("[TIMING] \(timestamp(), privacy: .public) JSON parsed (+\(String(format: "%.1f", parseTime.timeIntervalSince(stdinReadTime) * 1000), privacy: .public)ms)")

// Handle SessionEnd separately - just post removal notification
if hookEvent.hookEventName == "SessionEnd" {
    postSessionEnd(sessionId: hookEvent.sessionId)
    let totalTime = Date().timeIntervalSince(cliStartTime) * 1000
    logger.info("[TIMING] \(timestamp(), privacy: .public) SessionEnd posted, total=\(String(format: "%.1f", totalTime), privacy: .public)ms")
    exit(0)
}

// Check cache for TTY/bundleId (fast path)
let cachedEntry = ProcessTreeCache.get(sessionId: hookEvent.sessionId)
let cacheCheckTime = Date()
logger.info("[TIMING] \(timestamp(), privacy: .public) Cache check done, hit=\(cachedEntry != nil, privacy: .public) (+\(String(format: "%.1f", cacheCheckTime.timeIntervalSince(parseTime) * 1000), privacy: .public)ms)")

// Post initial event immediately with cached values (or nil if not cached)
let sendStartTime = Date()
logger.info("[TIMING] \(timestamp(), privacy: .public) Posting notification: session=\(hookEvent.sessionId.prefix(8), privacy: .public), event=\(hookEvent.hookEventName, privacy: .public)")

let initialEvent = SessionEvent(from: hookEvent, tty: cachedEntry?.tty, bundleId: cachedEntry?.bundleId)
postSessionEvent(initialEvent)

let sendEndTime = Date()
logger.info("[TIMING] \(timestamp(), privacy: .public) Notification posted (+\(String(format: "%.1f", sendEndTime.timeIntervalSince(sendStartTime) * 1000), privacy: .public)ms)")

// Spawn background process for slow lookups (metadata, process tree if not cached)
// This lets the main process exit immediately so Claude Code isn't blocked
if let hookEventJSON = String(data: inputData, encoding: .utf8) {
    spawnBackgroundUpdate(hookEventJSON: hookEventJSON, executablePath: args[0])
}

let totalTime = Date().timeIntervalSince(cliStartTime) * 1000
logger.info("[TIMING] \(timestamp(), privacy: .public) CLI exiting, total=\(String(format: "%.1f", totalTime), privacy: .public)ms")

exit(0)
