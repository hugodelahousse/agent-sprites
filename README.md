# AgentSprites

A macOS menu bar app for monitoring Claude Code instances with "desktop pet" style creatures called Sprites.

## Architecture

```
┌─────────────────┐     stdin JSON       ┌─────────────────┐
│  Claude Code    │ ──────────────────▶  │ agentsprites-cli│
│    Hooks        │                      │ (bundled in app)│
└─────────────────┘                      └────────┬────────┘
                                                  │ Distributed
                                                  │ Notification
                                                  ▼
                                         ┌─────────────────┐
                                         │ AgentSprites.app│
                                         │   (SwiftUI)     │
                                         └─────────────────┘
```

## Components

- **AgentSpritesCore**: Shared library with models (SessionState, SessionEvent, HookEvent)
- **agentsprites-cli**: Hook handler called by Claude Code, posts Distributed Notifications
- **AgentSprites.app**: SwiftUI menu bar app that receives notifications and displays sprites

## Building

```bash
# Build all targets
swift build

# Bundle as .app
make bundle

# Build release
make release
```

## Installation

```bash
# Full install (builds release, installs to /Applications)
make install
```

This will:
1. Build release binaries
2. Bundle the .app with embedded CLI
3. Install to `/Applications/AgentSprites.app`
4. Install character packs to `~/Library/Application Support/AgentSprites/Characters/`

On first launch, the app will prompt to install Claude Code hooks.

## Data Storage

All app data is stored in the standard macOS location:
```
~/Library/Application Support/AgentSprites/
└── Characters/          # Character packs (sprites)
    ├── slime/
    ├── pokemon/
    └── ...
```

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
echo '{"hook_event_name":"SessionStart","session_id":"test-123","cwd":"/tmp"}' | .build/debug/AgentSprites.app/Contents/Helpers/agentsprites-cli
```

## License

MIT
