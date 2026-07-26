#!/bin/zsh
# Signs dist/Louppe.zip and regenerates the signed Sparkle feed for a release.
# Run only after VERSION and CHANGELOG.md are final for the release.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION_FILE="$PWD/VERSION"
ARCHIVE="$PWD/dist/Louppe.zip"
MARKETING_VERSION="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD_NUMBER="$(awk -F= '$1 == "BUILD_NUMBER" { print $2 }' "$VERSION_FILE")"
TAG="v$MARKETING_VERSION"
ACCOUNT="com.alexandermarkin.louppe"
RELEASE_URL="https://github.com/alexander-markin-meow/louppe/releases/tag/$TAG"
DOWNLOAD_PREFIX="https://github.com/alexander-markin-meow/louppe/releases/download/$TAG/"

if [[ ! -f "$ARCHIVE" ]]; then
    echo "Missing dist/Louppe.zip. Run ./build_app.sh first." >&2
    exit 1
fi

SPARKLE_TOOLS="$(find .build/artifacts -type d \
    -path '*/Sparkle/bin' -print -quit)"
if [[ -z "$SPARKLE_TOOLS" || ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
    echo "Sparkle's release tools were not found. Run swift package --disable-keychain resolve first." >&2
    exit 1
fi

WORK_DIR="$(mktemp -d /private/tmp/Louppe-update.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT
cp "$ARCHIVE" "$WORK_DIR/Louppe.zip"

# Give Sparkle just the current release's notes. Embedding them keeps the
# update window independent from a separate web page and signs the text as
# part of the feed.
awk -v heading="## $MARKETING_VERSION ($BUILD_NUMBER)" '
    index($0, heading) == 1 { copying = 1; next }
    copying && /^## / { exit }
    copying { print }
' CHANGELOG.md > "$WORK_DIR/Louppe.md"

if [[ ! -s "$WORK_DIR/Louppe.md" ]]; then
    echo "CHANGELOG.md has no notes for $MARKETING_VERSION ($BUILD_NUMBER)." >&2
    exit 1
fi

"$SPARKLE_TOOLS/generate_appcast" \
    --account "$ACCOUNT" \
    --download-url-prefix "$DOWNLOAD_PREFIX" \
    --embed-release-notes \
    --link "$RELEASE_URL" \
    --maximum-versions 1 \
    --maximum-deltas 0 \
    -o "$PWD/appcast.xml" \
    "$WORK_DIR"

"$SPARKLE_TOOLS/sign_update" \
    --account "$ACCOUNT" \
    --verify "$PWD/appcast.xml"

echo ""
echo "Prepared signed update feed for Louppe $MARKETING_VERSION ($BUILD_NUMBER)."
echo "Upload this exact archive to GitHub release $TAG:"
echo "  $ARCHIVE"
echo "Then commit and push:"
echo "  appcast.xml"
