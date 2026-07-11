#!/bin/zsh
# Builds Loupe.app from source. Run:  ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

echo "Compiling (release build)…"
swift build -c release

APP_DIR="dist/Louppe.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

cp .build/release/Loupe "$APP_DIR/Contents/MacOS/Loupe"
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
    <string>com.alexandermarkin.loupe</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>Loupe</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
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

echo ""
echo "Done → $PWD/$APP_DIR"
