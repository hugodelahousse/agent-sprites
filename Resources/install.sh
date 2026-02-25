#!/bin/bash
set -e

# AgentSprites Installation Script

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
INSTALL_DIR="$HOME/.agentsprites"
BIN_DIR="$INSTALL_DIR/bin"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
PLIST_NAME="com.agentsprites.daemon.plist"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

echo "=== AgentSprites Installer ==="
echo ""

# Build release binaries
echo "Building release binaries..."
cd "$PROJECT_DIR"
swift build -c release

# Create installation directories
echo "Creating installation directories..."
mkdir -p "$BIN_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"

# Copy binaries
echo "Installing binaries to $BIN_DIR..."
cp ".build/release/agentsprites-daemon" "$BIN_DIR/"
cp ".build/release/agentsprites-cli" "$BIN_DIR/"
cp ".build/release/AgentSprites" "$BIN_DIR/"
chmod +x "$BIN_DIR/agentsprites-daemon"
chmod +x "$BIN_DIR/agentsprites-cli"
chmod +x "$BIN_DIR/AgentSprites"

# Unload existing daemon if present
if launchctl print "gui/$(id -u)/com.agentsprites.daemon" &>/dev/null; then
    echo "Stopping existing daemon..."
    launchctl bootout "gui/$(id -u)/com.agentsprites.daemon" 2>/dev/null || true
fi

# Install launchd plist with path substitution
echo "Installing launchd plist..."
sed -e "s|__AGENTSPRITES_BIN__|$BIN_DIR|g" \
    -e "s|__AGENTSPRITES_DIR__|$INSTALL_DIR|g" \
    "$SCRIPT_DIR/$PLIST_NAME" > "$LAUNCH_AGENTS_DIR/$PLIST_NAME"

# Load the daemon
echo "Loading daemon..."
launchctl bootstrap "gui/$(id -u)" "$LAUNCH_AGENTS_DIR/$PLIST_NAME"
launchctl kickstart "gui/$(id -u)/com.agentsprites.daemon"

# Configure Claude Code hooks
echo "Configuring Claude Code hooks..."
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"

CLI_PATH="$BIN_DIR/agentsprites-cli"
HOOK_CONFIG=$(cat <<EOF
{
  "type": "command",
  "command": "$CLI_PATH",
  "timeout": 5000,
  "async": true
}
EOF
)

# Create or update settings.json with hooks
if [ -f "$CLAUDE_SETTINGS" ]; then
    # Backup existing settings
    cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.backup.$(date +%Y%m%d%H%M%S)"

    # Use Python to merge hooks (available on macOS by default)
    python3 << PYTHON_SCRIPT
import json
import sys

settings_path = "$CLAUDE_SETTINGS"
cli_path = "$CLI_PATH"

hook_events = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "PermissionRequest",
    "SubagentStart",
    "PostToolUseFailure",
    "PreCompact"
]

# New format requires matcher wrapper
hook_entry = {
    "matcher": "",
    "hooks": [
        {
            "type": "command",
            "command": cli_path,
            "timeout": 5000,
            "async": True
        }
    ]
}

try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    settings = {}

if 'hooks' not in settings:
    settings['hooks'] = {}

for event in hook_events:
    if event not in settings['hooks']:
        settings['hooks'][event] = []

    # Check if our hook is already configured (look inside hooks array)
    existing = False
    for entry in settings['hooks'][event]:
        if 'hooks' in entry:
            for h in entry['hooks']:
                if h.get('command') == cli_path:
                    existing = True
                    break
    if not existing:
        settings['hooks'][event].append(json.loads(json.dumps(hook_entry)))

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print("Hooks configured successfully")
PYTHON_SCRIPT

else
    # Create new settings file
    python3 << PYTHON_SCRIPT
import json

settings_path = "$CLAUDE_SETTINGS"
cli_path = "$CLI_PATH"

hook_events = [
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "Stop",
    "Notification",
    "PermissionRequest",
    "SubagentStart",
    "PostToolUseFailure",
    "PreCompact"
]

# New format requires matcher wrapper
hook_entry = {
    "matcher": "",
    "hooks": [
        {
            "type": "command",
            "command": cli_path,
            "timeout": 5000,
            "async": True
        }
    ]
}

settings = {"hooks": {}}
for event in hook_events:
    settings['hooks'][event] = [json.loads(json.dumps(hook_entry))]

with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2)

print("Settings file created with hooks")
PYTHON_SCRIPT
fi

echo ""
echo "=== Installation Complete ==="
echo ""
echo "Binaries installed to: $BIN_DIR"
echo "Daemon plist installed to: $LAUNCH_AGENTS_DIR/$PLIST_NAME"
echo "Claude Code hooks configured in: $CLAUDE_SETTINGS"
echo ""
echo "To verify daemon is running:"
echo "  launchctl print gui/\$(id -u)/com.agentsprites.daemon"
echo ""
echo "To view daemon logs:"
echo "  tail -f $INSTALL_DIR/daemon.log"
echo ""
echo "To uninstall:"
echo "  launchctl bootout gui/\$(id -u)/com.agentsprites.daemon"
echo "  rm -rf $INSTALL_DIR"
echo "  rm $LAUNCH_AGENTS_DIR/$PLIST_NAME"
