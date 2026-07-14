#!/bin/zsh
# Builds Louppe.app from source. Run:  ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "Compiling (release build)…"
swift build -c release

OUTPUT_APP="dist/Louppe.app"
# This repository can live in a File Provider-managed Documents folder, which
# immediately reattaches com.apple.FinderInfo to app bundles and makes strict
# signature verification fail. Assemble and verify on the local temp volume,
# then copy the verified bundle back without extended attributes.
STAGING_ROOT="$(mktemp -d /private/tmp/Louppe-build.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/Louppe.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/Louppe "$APP_DIR/Contents/MacOS/Louppe"
cp AppIcon/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Louppe</string>
    <key>CFBundleDisplayName</key>
    <string>Louppe</string>
    <key>CFBundleIdentifier</key>
    <string>com.alexandermarkin.louppe</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Louppe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>NSHumanReadableCopyright</key>
    <string>© 2026 Alex Markin</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
</dict>
</plist>
PLIST

xattr -cr "$APP_DIR"
codesign --force --sign - "$APP_DIR"
codesign --verify --deep --strict "$APP_DIR"

rm -rf "$OUTPUT_APP"
mkdir -p "$(dirname "$OUTPUT_APP")"
ditto --noextattr --noqtn "$APP_DIR" "$OUTPUT_APP"

echo ""
echo "Done → $PWD/$OUTPUT_APP"
