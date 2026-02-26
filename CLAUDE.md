# AgentSprites - Swift Development Guide

## Build & Run
- Build: `make build` or `swift build`
- Build release: `make release`
- Run: `make run`
- Install (full): `make install` - builds release, installs to ~/.agentsprites, configures Claude hooks
- Restart (dev): `make restart` - rebuilds debug, installs binaries, restarts daemon + app
- Restart daemon only: `make restart-daemon`
- Restart app only: `make restart-app`
- Setup characters: `make setup-characters` (auto-runs on build)
- Run tests: `swift test`
- Lint: `make lint` (SwiftLint)
- Lint & fix: `make lint-fix`
- Format: `make format` (SwiftFormat)
- Format check: `make format-check` (dry-run)
- Clean: `make clean`

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

## Swift Standards (Swift 5.9, macOS 13+)

### Concurrency
- ALWAYS use `async/await`, `Actor`, `@MainActor`, `@Sendable` over GCD/completion handlers
- Use `TaskGroup` and `AsyncStream` for structured concurrency
- Exception: `DispatchSemaphore` is acceptable in CLI for synchronous XPC calls
- Prefer `.task { }` modifier over `.onAppear + Task { }` for async work in SwiftUI

### Value Types
- Prefer `struct` and `enum` over `class` unless reference semantics are needed
- Classes are appropriate for: caches (`SpriteCharacter`), AppKit wrappers (`BlobWindowController`), view models with identity

### Modern Syntax
- Use `if let` shorthand (Swift 5.7+): `if let foo` not `if let foo = foo`
- Use `guard` for early exits
- Use pattern matching where it simplifies conditionals
- Consider `package` access control where it fits better than `public`/`internal`

### Safety
- Avoid force unwraps (`!`) — use `guard let`, `if let`, or `??` with defaults
- Avoid force casts (`as!`) — use `as?` with proper handling
- Exception: Force unwrap acceptable after explicit existence checks

### Logging
- ALWAYS use `os.Logger` — never `print()`, `NSLog()`, or third-party logging
- Subsystem pattern: `com.agentsprites.<cli|daemon|app>`
- Use privacy annotations: `\(variable, privacy: .public)` for non-sensitive data
- Include timing info for performance-critical paths using `timestamp()` helper

### Serialization
- Use `Codable` with custom `CodingKeys` when JSON keys differ
- Use `JSONEncoder`/`JSONDecoder` with consistent strategies
- Never use SwiftyJSON, ObjectMapper, or manual JSON parsing
- Prefer `Decodable` structs over dictionaries for API responses

### Persistence
- `UserDefaults`/`@AppStorage` for simple preferences only
- Never store sensitive data (tokens, passwords) in UserDefaults — use Keychain
- Use `FileManager` with proper directory APIs, not hardcoded paths
- Project-defined paths like `~/.agentsprites/` are acceptable

### SwiftUI
- Extract subviews when `body` exceeds ~50 lines
- `@State` for local/private state, `@Binding` for parent-owned state
- `@StateObject` for owned view models, `@ObservedObject` for passed-in
- Use `@ViewBuilder` for conditional view composition
- Avoid `AnyView` — use generics or `@ViewBuilder` instead
- Use `NavigationStack` (macOS 13+) over deprecated `NavigationView`

### Dependency Injection
- Prefer `@Environment` and custom `EnvironmentKey` over singletons in SwiftUI
- Singletons acceptable for: loading caches (`CharacterManager`), truly global state
- Feature flags should be type-safe (enum/struct), not stringly-typed

### Error Handling
- Define error `enum` types conforming to `LocalizedError`
- Never use empty `catch` blocks
- Never `catch` just to `print` — handle or propagate
- `try?` acceptable for optional loading, prefer explicit handling otherwise

### Performance (Critical)
This app runs continuously in the background - CPU/memory efficiency is paramount.

**Animation & Rendering:**
- Never recreate SwiftUI views every frame - use `@ObservedObject`/`@Published` to update existing views
- Stop CVDisplayLink/timers when there's nothing to animate (no active blobs)
- Only update window positions when they actually change
- Use reference equality (`===`) for images to avoid unnecessary diffing

**SwiftUI Efficiency:**
- Avoid creating new view structs in hot paths (animation loops, timers)
- Use observable models with `@Published` properties for frequently-updated state
- Minimize view body complexity - extract static parts into separate views
- Compare values before updating `@Published` properties to prevent unnecessary invalidation

**General:**
- Profile with Instruments before and after changes to animation/rendering code
- Aim for <1% CPU when idle with no active sessions
- Cache expensive computations (window ledge detection is already cached at 500ms)
- Use `Task.sleep` with reasonable intervals, not busy loops

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
