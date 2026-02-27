#!/bin/bash
set -e

# Bundle AgentSprites as a proper .app with embedded CLI

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/.build"
CONFIG="${1:-debug}"  # debug or release

echo "Bundling AgentSprites.app ($CONFIG)..."

# Paths
APP_EXECUTABLE="$BUILD_DIR/$CONFIG/AgentSprites"
CLI_EXECUTABLE="$BUILD_DIR/$CONFIG/agentsprites-cli"
APP_BUNDLE="$BUILD_DIR/$CONFIG/AgentSprites.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS="$CONTENTS/MacOS"
HELPERS="$CONTENTS/Helpers"
RESOURCES="$CONTENTS/Resources"

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

# Create bundle structure
rm -rf "$APP_BUNDLE"
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
cat > "$CONTENTS/Info.plist" << 'EOF'
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
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
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

# Sign the bundle (ad-hoc for local use)
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "Created: $APP_BUNDLE"
echo "  - Main app: $MACOS/AgentSprites"
echo "  - CLI: $HELPERS/agentsprites-cli"
