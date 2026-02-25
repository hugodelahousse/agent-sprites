# AgentSprites

A macOS desktop widget system for monitoring Claude Code instances with "desktop pet" style creatures called Sprites.

## Architecture

```
┌─────────────────┐     stdin JSON       ┌─────────────────┐
│  Claude Code    │ ──────────────────▶  │ agentsprites-cli│
│    Hooks        │                      │  (SPM executable)│
└─────────────────┘                      └────────┬────────┘
                                                  │ XPC
                                                  ▼
┌─────────────────┐     XPC Callback     ┌─────────────────┐
│ AgentSprites.app│ ◀────────────────── │agentsprites-    │
│   (SwiftUI)     │                      │daemon (launchd) │
└─────────────────┘                      └─────────────────┘
```

## Components

- **AgentSpritesCore**: Shared library with models and XPC protocol
- **agentsprites-daemon**: launchd agent providing XPC service for state management
- **agentsprites-cli**: Hook handler called by Claude Code hooks
- **AgentSprites.app**: SwiftUI menu bar app displaying session states

## Building

```bash
# Build all targets
swift build

# Build release
swift build -c release

# Run tests
swift test
```

## Installation

```bash
# Run the install script
bash Resources/install.sh
```

This will:
1. Build release binaries
2. Install to `~/.agentsprites/bin/`
3. Install launchd plist to `~/Library/LaunchAgents/`
4. Register hooks in `~/.claude/settings.json`

## Session States

| Status | Trigger Event | Visual |
|--------|---------------|--------|
| idle | SessionStart, 5s after done | Gray |
| working | UserPromptSubmit | Blue |
| waitingForInput | Notification (elicitation) | Yellow |
| waitingForPermission | PermissionRequest | Red |
| error | PostToolUseFailure | Red |
| done | Stop | Green |

## Manual Testing

```bash
# Test CLI with mock hook event
echo '{"hook_event_name":"SessionStart","session_id":"test-123","cwd":"/tmp"}' | .build/debug/agentsprites-cli

# Check daemon status
launchctl print gui/$(id -u)/com.agentsprites.daemon
```

## License

MIT
