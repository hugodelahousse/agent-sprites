import AgentSpritesCore
import Foundation

// MARK: - CLI Argument Parsing

struct StressConfig {
    var sessions: Int = 20
    var duration: TimeInterval = 60
    var rate: TimeInterval = 0.5
    var burst: Bool = false
    var instant: Bool = false

    static func parse(_ args: [String]) -> Self {
        var config = Self()
        var i = 1  // skip executable name
        while i < args.count {
            switch args[i] {
            case "--sessions":
                i += 1
                config.sessions = Int(args[i]) ?? config.sessions
            case "--duration":
                i += 1
                config.duration = TimeInterval(args[i]) ?? config.duration
            case "--rate":
                i += 1
                config.rate = TimeInterval(args[i]) ?? config.rate
            case "--burst":
                config.burst = true
            case "--instant":
                config.instant = true
            case "--help", "-h":
                printUsage()
                exit(0)
            default:
                print("Unknown argument: \(args[i])")
                printUsage()
                exit(1)
            }
            i += 1
        }
        return config
    }

    static func printUsage() {
        print("""
        Usage: agentsprites-stress [OPTIONS]

        Stress test for AgentSprites — simulates concurrent Claude Code sessions.

        Options:
          --sessions N    Number of concurrent sessions (default: 20)
          --duration S    Duration in seconds (default: 60)
          --rate R        Seconds between events per session (default: 0.5)
          --burst         Fire events with no delay (burst load test)
          --instant       Start all sessions immediately (no ramp-up)
          --help, -h      Show this help
        """)
    }
}

// MARK: - Event Sequence Generation

/// Generates a realistic sequence of event names for a session lifecycle
struct EventSequenceGenerator {
    private var index = 0
    private var sequence: [EventStep] = []

    enum EventStep {
        case event(name: String, notificationType: String? = nil)
    }

    init() {
        regenerate()
    }

    /// Generate a new random lifecycle sequence
    mutating func regenerate() {
        index = 0
        sequence = []

        // SessionStart
        sequence.append(.event(name: "SessionStart"))

        // 2-5 work cycles before done
        let cycles = Int.random(in: 2 ... 5)
        for _ in 0 ..< cycles {
            // User submits a prompt
            sequence.append(.event(name: "UserPromptSubmit"))

            // Working phase: random mix of subagent/tool events
            let workEvents = Int.random(in: 1 ... 4)
            for _ in 0 ..< workEvents {
                let roll = Int.random(in: 0 ..< 100)
                if roll < 30 {
                    // Subagent start/stop pair
                    sequence.append(.event(name: "SubagentStart"))
                    sequence.append(.event(name: "SubagentStop"))
                } else if roll < 50 {
                    // Permission request then tool use (granted)
                    sequence.append(.event(name: "PermissionRequest"))
                    sequence.append(.event(name: "PostToolUse"))
                } else if roll < 65 {
                    // Notification: elicitation dialog
                    sequence.append(.event(name: "Notification", notificationType: "elicitation_dialog"))
                    sequence.append(.event(name: "UserPromptSubmit"))
                } else if roll < 75 {
                    // Notification: permission prompt then tool use
                    sequence.append(.event(name: "Notification", notificationType: "permission_prompt"))
                    sequence.append(.event(name: "PostToolUse"))
                } else if roll < 80 {
                    // Error then recovery
                    sequence.append(.event(name: "PostToolUseFailure"))
                    sequence.append(.event(name: "UserPromptSubmit"))
                } else if roll < 90 {
                    // PreCompact
                    sequence.append(.event(name: "PreCompact"))
                } else {
                    // Just a tool use
                    sequence.append(.event(name: "PostToolUse"))
                }
            }
        }

        // Stop
        sequence.append(.event(name: "Stop"))
    }

    /// Get the next event step, or nil if sequence is exhausted
    mutating func next() -> EventStep? {
        guard index < sequence.count else { return nil }
        let step = sequence[index]
        index += 1
        return step
    }
}

// MARK: - Notification Poster

func postSessionEvent(_ event: SessionEvent) {
    guard let json = event.toJSONString() else {
        print("ERROR: Failed to encode event")
        return
    }

    DistributedNotificationCenter.default().postNotificationName(
        AgentSpritesConstants.sessionEventNotification,
        object: nil,
        userInfo: ["eventJSON": json],
        deliverImmediately: true
    )
}

func postSessionEnd(sessionId: String) {
    DistributedNotificationCenter.default().postNotificationName(
        AgentSpritesConstants.sessionEndNotification,
        object: nil,
        userInfo: ["sessionId": sessionId],
        deliverImmediately: true
    )
}

// MARK: - Session Simulator

actor StressRunner {
    let config: StressConfig
    private var totalEvents = 0
    private var isRunning = true
    private let startTime = Date()

    init(config: StressConfig) {
        self.config = config
    }

    func incrementEvents() {
        totalEvents += 1
    }

    func stop() {
        isRunning = false
    }

    var running: Bool { isRunning }
    var eventCount: Int { totalEvents }
    var elapsed: TimeInterval { Date().timeIntervalSince(startTime) }

    func printStats() {
        let elapsed = Date().timeIntervalSince(startTime)
        let rate = elapsed > 0 ? Double(totalEvents) / elapsed : 0
        print("\n--- Stress Test Complete ---")
        print("Sessions: \(config.sessions)")
        print("Duration: \(String(format: "%.1f", elapsed))s")
        print("Total events: \(totalEvents)")
        print("Events/sec: \(String(format: "%.1f", rate))")
    }
}

// MARK: - Main

let config = StressConfig.parse(CommandLine.arguments)
let runner = StressRunner(config: config)

let branches = ["main", "feature/auth", "fix/crash", "refactor/ui", "dev", "staging"]
let summaries = [
    "Implementing authentication flow",
    "Fixing crash in session manager",
    "Refactoring sprite rendering",
    "Adding unit tests",
    "Updating dependencies",
    "Code review changes",
    "Debugging notification handling",
    "Optimizing texture cache"
]

print("AgentSprites Stress Test")
print("========================")
print("Sessions: \(config.sessions)")
print("Duration: \(config.duration)s")
print("Event rate: \(config.burst ? "burst (no delay)" : "\(config.rate)s per session")")
print("Ramp-up: \(config.instant ? "instant" : "staggered over 2s")")
print("")

struct SessionInfo {
    let id: String
    let dir: String
    let branch: String
    let summary: String
}

// Generate session IDs and directories
let sessionInfos: [SessionInfo] = (0 ..< config.sessions).map { i in
    SessionInfo(
        id: UUID().uuidString,
        dir: "/tmp/stress-test/project-\(i + 1)",
        branch: branches[i % branches.count],
        summary: summaries[i % summaries.count]
    )
}

// Launch session tasks
await withTaskGroup(of: Void.self) { group in
    // Session simulation tasks
    for (index, info) in sessionInfos.enumerated() {
        group.addTask {
            // Stagger start
            if !config.instant {
                let staggerDelay = Double(index) / Double(config.sessions) * 2.0
                try? await Task.sleep(nanoseconds: UInt64(staggerDelay * 1_000_000_000))
            }

            var generator = EventSequenceGenerator()

            while await runner.running {
                if let step = generator.next() {
                    switch step {
                    case .event(let name, let notificationType):
                        let event = SessionEvent(
                            sessionId: info.id,
                            eventName: name,
                            workingDirectory: info.dir,
                            tty: "/dev/ttys\(String(format: "%03d", index))",
                            bundleId: "com.apple.Terminal",
                            summary: info.summary,
                            gitBranch: info.branch,
                            notificationType: notificationType
                        )
                        postSessionEvent(event)
                        await runner.incrementEvents()

                        if !config.burst {
                            // Vary the rate slightly per event
                            let jitter = Double.random(in: 0.5 ... 1.5)
                            let delay = config.rate * jitter
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        }
                    }
                } else {
                    // Sequence exhausted — pause briefly then start a new lifecycle
                    if !config.burst {
                        // Simulate done→idle delay
                        try? await Task.sleep(nanoseconds: 3_000_000_000)
                    }
                    generator.regenerate()
                }
            }
        }
    }

    // Duration timer
    group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(config.duration * 1_000_000_000))
        await runner.stop()
    }

    // Progress reporter
    group.addTask {
        while await runner.running {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if await runner.running {
                let count = await runner.eventCount
                let elapsed = await runner.elapsed
                let rate = elapsed > 0 ? Double(count) / elapsed : 0
                print("[\(String(format: "%.0f", elapsed))s] Events: \(count) (\(String(format: "%.1f", rate))/s)")
            }
        }
    }
}

// Clean up: remove all sessions
print("\nCleaning up sessions...")
for info in sessionInfos {
    postSessionEnd(sessionId: info.id)
}

// Brief pause to let notifications deliver
try? await Task.sleep(nanoseconds: 500_000_000)

await runner.printStats()
