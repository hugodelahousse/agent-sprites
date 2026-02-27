#!/bin/bash
set -e

# AgentSprites Installation Script
# Installs the .app bundle and character packs

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_SUPPORT_DIR="$HOME/Library/Application Support/AgentSprites"
CHARACTERS_DIR="$APP_SUPPORT_DIR/Characters"

echo "=== AgentSprites Installer ==="
echo ""

# Build release
echo "Building release..."
cd "$PROJECT_DIR"
swift build -c release

# Bundle the app
echo "Creating app bundle..."
bash "$SCRIPT_DIR/bundle-app.sh" release

# Install app bundle to /Applications
echo "Installing AgentSprites.app to /Applications..."
rm -rf "/Applications/AgentSprites.app"
cp -r ".build/release/AgentSprites.app" "/Applications/"

# Install character packs
echo "Installing character packs..."
mkdir -p "$CHARACTERS_DIR"
for pack in CharacterPacks/*/; do
    name=$(basename "$pack")
    rm -rf "$CHARACTERS_DIR/$name"
    cp -r "$pack" "$CHARACTERS_DIR/$name"
done
cp CharacterPacks/sprites-config.json "$CHARACTERS_DIR/" 2>/dev/null || true

echo ""
echo "=== Installation Complete ==="
echo ""
echo "App installed to: /Applications/AgentSprites.app"
echo "Character packs: $CHARACTERS_DIR"
echo ""
echo "To start the app:"
echo "  open /Applications/AgentSprites.app"
echo ""
echo "The app will prompt to install Claude Code hooks on first run."
echo ""
echo "To uninstall:"
echo "  rm -rf /Applications/AgentSprites.app"
echo "  rm -rf \"$APP_SUPPORT_DIR\""
echo ""
