#!/bin/bash
set -e

# Bundle AgentSprites as a proper .app with embedded CLI

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
CONFIG="${1:-debug}"  # debug or release

echo "Bundling AgentSprites.app ($CONFIG)..."

# Get version from git tag (strip leading 'v')
GIT_VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')
if [ -z "$GIT_VERSION" ]; then
    GIT_VERSION="0.0.0"
fi
echo "  - Version: $GIT_VERSION"

# Paths
APP_EXECUTABLE="$BUILD_DIR/$CONFIG/AgentSprites"
CLI_EXECUTABLE="$BUILD_DIR/$CONFIG/agentsprites-cli"
APP_BUNDLE="$BUILD_DIR/$CONFIG/AgentSprites.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
RESOURCES="$CONTENTS/Resources"
HASH_FILE="$CONTENTS/.executable-hashes"

# Check executables exist
if [ ! -f "$APP_EXECUTABLE" ]; then
    echo "Error: AgentSprites executable not found at $APP_EXECUTABLE"
    echo "Run 'swift build' first"
    exit 1
fi

if [ ! -f "$CLI_EXECUTABLE" ]; then
    echo "Error: agentsprites-cli executable not found at $CLI_EXECUTABLE"
    echo "Run 'swift build' first"
    exit 1
fi

# Compute current hashes of source executables
CURRENT_HASHES="$(shasum "$APP_EXECUTABLE" "$CLI_EXECUTABLE")"

# Check if executables changed since last bundle.
# Re-signing invalidates macOS accessibility grants, so we skip it when possible.
NEEDS_RESIGN=true
if [ -f "$HASH_FILE" ]; then
    PREV_HASHES="$(cat "$HASH_FILE")"
    if [ "$CURRENT_HASHES" = "$PREV_HASHES" ]; then
        NEEDS_RESIGN=false
    fi
fi

# Create bundle structure
mkdir -p "$MACOS"
mkdir -p "$HELPERS"
mkdir -p "$RESOURCES"
mkdir -p "$RESOURCES/CharacterPacks"

# Copy executables
cp "$APP_EXECUTABLE" "$MACOS/"
cp "$CLI_EXECUTABLE" "$HELPERS/"
chmod +x "$MACOS/AgentSprites"
chmod +x "$HELPERS/agentsprites-cli"

# Copy bundled character packs (slime is the default)
SLIME_PACK="$PROJECT_DIR/CharacterPacks/slime"
if [ -d "$SLIME_PACK" ]; then
    cp -r "$SLIME_PACK" "$RESOURCES/CharacterPacks/"
    echo "  - Bundled pack: slime"
fi

# Copy app icons
# AppIcon.icon (macOS 15+) and AppIcon.icns (fallback for older versions)
cp -r "$SCRIPT_DIR/AppIcon.icon" "$RESOURCES/"
cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES/"
echo "  - App icons: AppIcon.icon, AppIcon.icns"

# Create Info.plist
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>AgentSprites</string>
    <key>CFBundleIdentifier</key>
    <string>com.agentsprites.app</string>
    <key>CFBundleName</key>
    <string>AgentSprites</string>
    <key>CFBundleDisplayName</key>
    <string>AgentSprites</string>
    <key>CFBundleVersion</key>
    <string>${GIT_VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${GIT_VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

# Only re-sign if executables changed (preserves accessibility grants across rebuilds)
if [ "$NEEDS_RESIGN" = true ]; then
    codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true
    echo "$CURRENT_HASHES" > "$HASH_FILE"
    echo "  - Re-signed bundle"
fi

echo "Created: $APP_BUNDLE"
echo "  - Main app: $MACOS/AgentSprites"
echo "  - CLI: $HELPERS/agentsprites-cli"
