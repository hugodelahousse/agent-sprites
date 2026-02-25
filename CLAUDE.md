# AgentSprites - Swift Development Guide

## Build & Run
- Build all: `swift build`
- Build release: `swift build -c release`
- Run tests: `swift test`
- Clean: `swift package clean`

## Project Structure
- `AgentSpritesCore`: Shared library with models and XPC protocol
- `agentsprites-daemon`: launchd agent providing XPC service
- `agentsprites-cli`: Hook handler called by Claude Code
- `AgentSprites`: SwiftUI menu bar app

## Code Style
- Follow Swift API Design Guidelines
- Use Swift's native concurrency (async/await) over completion handlers
- Mark types as Sendable when crossing actor boundaries
- Use @MainActor for UI-related code
- Prefer structs over classes unless reference semantics needed

## XPC Patterns
- Protocol must be @objc for NSXPCInterface
- Use NSSecureCoding for custom types across XPC boundary
- Handle connection interruption/invalidation gracefully
- Daemon registers Mach service via launchd plist MachServices key

## SwiftUI Patterns
- Use @StateObject for owned view models
- Use @ObservedObject for passed-in view models
- MenuBarExtra for menu bar apps (macOS 13+)
- WindowGroup with id for multiple window types

## Testing
- XCTest for unit tests
- Test models and state machine logic in AgentSpritesCore
- Mock XPC connections for integration tests

## Debugging & Logging
The CLI uses `os.Logger` (subsystem: `com.agentsprites.cli`) for unified logging.

**Stream logs in real-time:**
```bash
log stream --predicate 'subsystem == "com.agentsprites.cli"' --level debug 2>&1 | tee /tmp/agentsprites-debug.log
```

**View recent logs:**
```bash
log show --predicate 'subsystem == "com.agentsprites.cli"' --last 10m --level debug
```

## Common Issues
- XPC requires code signing for production
- launchd plist must be in ~/Library/LaunchAgents for user agents
- MenuBarExtra requires .menuBarExtraStyle(.window) for custom views
- Use `launchctl bootstrap gui/$(id -u) <plist>` to load daemon
- Use `launchctl kickstart gui/$(id -u)/com.agentsprites.daemon` to start

## Session States
| Status | Trigger Event | Color |
|--------|---------------|-------|
| idle | SessionStart, Notification(idle_prompt), 5s after done | Gray |
| working | UserPromptSubmit, SubagentStart, SubagentStop, PreCompact, Notification(auth_success) | Blue |
| waitingForInput | Notification(elicitation_dialog) | Yellow |
| waitingForPermission | PermissionRequest, Notification(permission_prompt) | Red |
| error | PostToolUseFailure | Red |
| done | Stop | Green |

## Notification Types
| notification_type | Maps To | Description |
|-------------------|---------|-------------|
| elicitation_dialog | waitingForInput | Claude asking user a question |
| permission_prompt | waitingForPermission | Permission dialog shown |
| idle_prompt | idle | Agent is idle waiting for user |
| auth_success | working | Authentication succeeded (informational) |
