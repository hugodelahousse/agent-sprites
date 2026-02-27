# AgentSprites - Swift Development Guide

## Build & Run
- Build: `make build` or `swift build`
- Bundle: `make bundle` - creates .app bundle with embedded CLI
- Build release: `make release` - builds release and creates .app bundle
- Run: `make run` - builds, bundles, and opens app
- Install: `make install` - builds release, installs .app to /Applications
- Restart (dev): `make restart` - rebuilds, bundles, restarts app
- Restart app only: `make restart-app`
- Run tests: `swift test`
- Lint: `make lint` (SwiftLint)
- Lint & fix: `make lint-fix`
- Format: `make format` (SwiftFormat)
- Format check: `make format-check` (dry-run)
- Clean: `make clean`

## Project Structure
- `AgentSpritesCore`: Shared library with models (SessionState, SessionEvent, HookEvent)
- `agentsprites-cli`: Hook handler called by Claude Code, posts Distributed Notifications
- `AgentSprites`: SwiftUI menu bar app that receives notifications and displays sprites

## App Bundle Structure
```
AgentSprites.app/
├── Contents/
│   ├── Info.plist
│   ├── MacOS/
│   │   └── AgentSprites       # Main app executable
│   ├── Helpers/
│   │   └── agentsprites-cli   # Bundled CLI for hooks
│   └── Resources/
```

The CLI is bundled inside the app. On first launch, the app prompts to install Claude Code hooks pointing to the bundled CLI.

## Architecture
The app uses **Distributed Notifications** for IPC between CLI and App:
- CLI receives hook events from Claude Code via stdin
- CLI posts `SessionEvent` as JSON via `DistributedNotificationCenter`
- App receives notifications and updates session state via `SessionManager` actor
- CLI is bundled inside .app - no separate installation needed
- App handles hook installation via `HookInstaller` service

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
- Prefer `.task { }` modifier over `.onAppear + Task { }` for async work in SwiftUI

### Value Types
- Prefer `struct` and `enum` over `class` unless reference semantics are needed
- Classes are appropriate for: caches (`SpriteCharacter`), AppKit wrappers (`SpriteWindowController`), view models with identity

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
- Subsystem pattern: `com.agentsprites.<cli|app>`
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
- Use `AgentSpritesConstants.applicationSupportDirectory` for app data paths

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
- Stop CVDisplayLink/timers when there's nothing to animate (no active sprites)
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

## Distributed Notifications
IPC between CLI and App uses `DistributedNotificationCenter`:

**Notification Names (in AgentSpritesConstants):**
- `sessionEventNotification`: CLI posts session updates with JSON payload
- `sessionEndNotification`: CLI posts when a session ends

**Payload Format:**
```swift
// Session event (userInfo)
["eventJSON": String]  // JSON-encoded SessionEvent

// Session end (userInfo)
["sessionId": String]  // Session ID to remove
```

## SwiftUI Patterns
- Use @StateObject for owned view models
- Use @ObservedObject for passed-in view models
- MenuBarExtra for menu bar apps (macOS 13+)
- WindowGroup with id for multiple window types

## Testing
- XCTest for unit tests
- Test models and state machine logic in AgentSpritesCore

## Debugging & Logging
The CLI uses `os.Logger` (subsystem: `com.agentsprites.cli`) for unified logging.

**Stream logs in real-time:**
```bash
log stream --predicate 'subsystem BEGINSWITH "com.agentsprites"' --level debug
```

**View recent logs:**
```bash
log show --predicate 'subsystem BEGINSWITH "com.agentsprites"' --last 10m --level debug
```

## Common Issues
- MenuBarExtra requires .menuBarExtraStyle(.window) for custom views
- App must be running to receive notifications from CLI
- If sprites aren't updating, check if the app is running and hooks are installed
- Hooks point to bundled CLI path - moving the .app will break hooks (reinstall via menu)
- First-run hook prompt only shows if bundled CLI is detected

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
