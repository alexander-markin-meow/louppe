#!/bin/zsh
# Builds Louppe.app from source. Run:  ./build_app.sh
set -euo pipefail
cd "$(dirname "$0")"

VERSION_FILE="$PWD/VERSION"
CHANGELOG_FILE="$PWD/CHANGELOG.md"
MARKETING_VERSION="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD_NUMBER="$(awk -F= '$1 == "BUILD_NUMBER" { print $2 }' "$VERSION_FILE")"

if ! print -r -- "$MARKETING_VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Invalid MARKETING_VERSION in VERSION: $MARKETING_VERSION" >&2
    exit 1
fi
if ! print -r -- "$BUILD_NUMBER" | grep -Eq '^[1-9][0-9]*$'; then
    echo "Invalid BUILD_NUMBER in VERSION: $BUILD_NUMBER" >&2
    exit 1
fi
if ! grep -Fq "## $MARKETING_VERSION ($BUILD_NUMBER) " "$CHANGELOG_FILE"; then
    echo "CHANGELOG.md has no entry for version $MARKETING_VERSION ($BUILD_NUMBER)" >&2
    exit 1
fi

echo "Compiling Louppe $MARKETING_VERSION ($BUILD_NUMBER)…"
# Sparkle is a public, checksum-pinned binary. Do not ask macOS Keychain for
# unrelated github.com credentials while downloading it.
swift build --disable-keychain -c release

OUTPUT_APP="dist/Louppe.app"
OUTPUT_ARCHIVE="dist/Louppe.zip"
# This repository can live in a File Provider-managed Documents folder, which
# immediately reattaches com.apple.FinderInfo to app bundles and makes strict
# signature verification fail. Assemble and verify on the local temp volume,
# then copy the verified bundle back without extended attributes.
STAGING_ROOT="$(mktemp -d /private/tmp/Louppe-build.XXXXXX)"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/Louppe.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" \
    "$APP_DIR/Contents/Frameworks"

cp .build/release/Louppe "$APP_DIR/Contents/MacOS/Louppe"
cp AppIcon/AppIcon.icns "$APP_DIR/Contents/Resources/AppIcon.icns"
cp CHANGELOG.md "$APP_DIR/Contents/Resources/Version History.md"

SPARKLE_FRAMEWORK="$(find .build/artifacts -type d \
    -path '*/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework' \
    -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
    echo "Sparkle.framework was not found in SwiftPM's build artifacts." >&2
    exit 1
fi
# ditto preserves the framework's versioned symlinks and executable bits.
ditto --noextattr --noqtn "$SPARKLE_FRAMEWORK" \
    "$APP_DIR/Contents/Frameworks/Sparkle.framework"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
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
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$MARKETING_VERSION</string>
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
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/alexander-markin-meow/louppe/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUAutomaticallyUpdate</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <real>86400</real>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
    <key>SURequireSignedFeed</key>
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
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$STAGING_ROOT/Louppe.zip"
cp "$STAGING_ROOT/Louppe.zip" "$OUTPUT_ARCHIVE"

echo ""
echo "Done → $PWD/$OUTPUT_APP"
echo "Archive → $PWD/$OUTPUT_ARCHIVE"
