#!/usr/bin/env bash
# Build BMWPair.app — a macOS .app bundle that wraps the SwiftPM executable.
#
# Output: ./BMWPair.app (drag to /Applications or run in place)
#
# Requirements: Swift toolchain (Command Line Tools or Xcode)
# Usage: ./build-app.sh [release|debug]
#
# Distribution notes: this script produces an unsigned (or ad-hoc-signed) app.
# After downloading, users typically need to run:
#     xattr -dr com.apple.quarantine BMWPair.app
# to bypass Gatekeeper, OR right-click → Open the first time.

set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="BMWPair"
BUNDLE_ID="com.bmw-fork.bmwpair"
VERSION="0.4.7-bmw.2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "==> Building $APP_NAME ($CONFIG)..."
if [[ "$CONFIG" == "release" ]]; then
    swift build -c release
    BIN_DIR=".build/release"
else
    swift build
    BIN_DIR=".build/debug"
fi

BIN="$BIN_DIR/$APP_NAME"
[[ -x "$BIN" ]] || { echo "ERROR: $BIN not found"; exit 1; }

APP="$APP_NAME.app"
echo "==> Assembling $APP bundle..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>BMW Pair (Smartcar)</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

# Ad-hoc sign so the bundle has a valid signature (still triggers Gatekeeper
# quarantine on download but is otherwise launchable). Real distribution
# would notarize via an Apple Developer account.
echo "==> Ad-hoc code signing..."
codesign --force --deep --sign - "$APP" 2>&1 | tail -3

echo
echo "✓ Built $APP"
ls -la "$APP/Contents/"
echo
echo "Run with: open ./$APP"
echo "Or drag to /Applications."
echo
echo "If macOS refuses to open after download, run:"
echo "  xattr -dr com.apple.quarantine \"$APP\""
echo "or right-click the app → Open the first time."
