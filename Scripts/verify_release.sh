#!/bin/zsh
# Verifies the exact app/archive/feed inputs used for a Louppe release.
# Use --publishing after prepare_update_feed.sh; it additionally requires the
# feed to contain a current-version enclosure matching dist/Louppe.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

PUBLISHING=false
if [[ "${1:-}" == "--publishing" ]]; then
    PUBLISHING=true
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--publishing]" >&2
    exit 2
fi

VERSION_FILE="$PWD/VERSION"
CHANGELOG_FILE="$PWD/CHANGELOG.md"
APP="$PWD/dist/Louppe.app"
ARCHIVE="$PWD/dist/Louppe.zip"
APPCAST="$PWD/appcast.xml"
ACCOUNT="com.alexandermarkin.louppe"
EXPECTED_PUBLIC_KEY="ZT/Kv98/mVd/uo2iUyBb0Gj0ShZqZ+FdfthHBjyH86k="
EXPECTED_FEED_URL="https://raw.githubusercontent.com/alexander-markin-meow/louppe/main/appcast.xml"

MARKETING_VERSION="$(awk -F= '$1 == "MARKETING_VERSION" { print $2 }' "$VERSION_FILE")"
BUILD_NUMBER="$(awk -F= '$1 == "BUILD_NUMBER" { print $2 }' "$VERSION_FILE")"
EXPECTED_TAG="v$MARKETING_VERSION"
EXPECTED_DOWNLOAD_URL="https://github.com/alexander-markin-meow/louppe/releases/download/$EXPECTED_TAG/Louppe.zip"

fail() {
    echo "Release preflight failed: $1" >&2
    exit 1
}

plist_value() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

verify_app_bundle() {
    local bundle="$1"
    local label="$2"

    codesign --verify --deep --strict "$bundle"
    [[ "$(plist_value "$bundle" CFBundleIdentifier)" == "com.alexandermarkin.louppe" ]] \
        || fail "$label bundle identifier changed."
    [[ "$(plist_value "$bundle" CFBundleShortVersionString)" == "$MARKETING_VERSION" ]] \
        || fail "$label marketing version does not match VERSION."
    [[ "$(plist_value "$bundle" CFBundleVersion)" == "$BUILD_NUMBER" ]] \
        || fail "$label build number does not match VERSION."
    [[ "$(plist_value "$bundle" LSMultipleInstancesProhibited)" == "true" ]] \
        || fail "$label must prohibit a second app instance during file operations."
    [[ "$(plist_value "$bundle" SUFeedURL)" == "$EXPECTED_FEED_URL" ]] \
        || fail "$label embedded update feed URL is wrong."
    [[ "$(plist_value "$bundle" SUPublicEDKey)" == "$EXPECTED_PUBLIC_KEY" ]] \
        || fail "$label embedded Sparkle public key is wrong."
    [[ "$(plist_value "$bundle" SURequireSignedFeed)" == "true" ]] \
        || fail "$label does not require signed feeds."
    [[ "$(plist_value "$bundle" SUVerifyUpdateBeforeExtraction)" == "true" ]] \
        || fail "$label does not verify updates before extraction."
    [[ -d "$bundle/Contents/Frameworks/Sparkle.framework" ]] \
        || fail "$label does not embed Sparkle.framework."
    otool -L "$bundle/Contents/MacOS/Louppe" | grep -Fq "@rpath/Sparkle.framework" \
        || fail "$label executable is not linked to embedded Sparkle."
}

[[ "$MARKETING_VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] \
    || fail "VERSION has an invalid marketing version."
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] \
    || fail "VERSION has an invalid build number."
grep -Fq "## $MARKETING_VERSION ($BUILD_NUMBER) " "$CHANGELOG_FILE" \
    || fail "CHANGELOG.md has no matching top-level release entry."
[[ -d "$APP" ]] || fail "dist/Louppe.app is missing; run ./build_app.sh."
[[ -f "$ARCHIVE" ]] || fail "dist/Louppe.zip is missing; run ./build_app.sh."
[[ -f "$APPCAST" ]] || fail "appcast.xml is missing."

CHECK_DIR="$(mktemp -d /private/tmp/Louppe-preflight.XXXXXX)"
trap 'rm -rf "$CHECK_DIR"' EXIT
# File Provider metadata can immediately reappear on dist/. Verify a clean
# local-volume copy instead; the packaged archive is extracted and checked
# independently below without altering the zip.
VERIFIED_APP="$CHECK_DIR/LooseApp.app"
ditto --noextattr --noqtn "$APP" "$VERIFIED_APP"
xattr -cr "$VERIFIED_APP"
verify_app_bundle "$VERIFIED_APP" "the loose app's"

SPARKLE_TOOLS="$(find .build/artifacts -type d -path '*/Sparkle/bin' -print -quit)"
[[ -n "$SPARKLE_TOOLS" && -x "$SPARKLE_TOOLS/sign_update" ]] \
    || fail "Sparkle's verification tool is missing."
if $PUBLISHING; then
    # Sparkle's verifier intentionally reads the matching private key from the
    # release owner's Keychain. This is the authoritative cryptographic check.
    "$SPARKLE_TOOLS/sign_update" --account "$ACCOUNT" --verify "$APPCAST"
else
    # Routine local builds must not trigger a Keychain prompt. Structural
    # checks catch a missing/malformed signature block; --publishing detects
    # edits with the real key-backed verification immediately before upload.
    grep -Fq '<!-- sparkle-signatures:' "$APPCAST" \
        || fail "the appcast has no embedded Sparkle signature block."
    grep -Eq '^edSignature: [A-Za-z0-9+/]+={0,2}$' "$APPCAST" \
        || fail "the appcast signature block is malformed."
fi

EXTRACT_DIR="$CHECK_DIR/Archive"
mkdir -p "$EXTRACT_DIR"
ditto -x -k "$ARCHIVE" "$EXTRACT_DIR"
EXTRACTED_APP="$EXTRACT_DIR/Louppe.app"
[[ -d "$EXTRACTED_APP" ]] || fail "the archive does not contain Louppe.app."
verify_app_bundle "$EXTRACTED_APP" "the archived app's"
ARCHIVE_DIFFERENCES="$(rsync -rcln --delete --itemize-changes \
    "$VERIFIED_APP/Contents/" "$EXTRACTED_APP/Contents/")"
if [[ -n "$ARCHIVE_DIFFERENCES" ]]; then
    echo "$ARCHIVE_DIFFERENCES" >&2
    fail "the archive contents differ from the verified loose app."
fi

ITEM_COUNT="$(xmllint --xpath \
    'count(//*[local-name()="channel"]/*[local-name()="item"])' \
    "$APPCAST" 2>/dev/null)"
if [[ "$ITEM_COUNT" == "0" ]]; then
    $PUBLISHING && fail "the publishing feed has no release enclosure."
    echo "Signed feed is intentionally empty; no unpublished local build will be offered."
else
    FEED_BUILD="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="version"])[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_MARKETING="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="shortVersionString"])[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_URL="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@url)[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_LENGTH="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@length)[1])' \
        "$APPCAST" 2>/dev/null)"
    FEED_SIGNATURE="$(xmllint --xpath \
        'string((//*[local-name()="enclosure"]/@*[local-name()="edSignature"])[1])' \
        "$APPCAST" 2>/dev/null)"
    MINIMUM_SYSTEM="$(xmllint --xpath \
        'string((//*[local-name()="item"]/*[local-name()="minimumSystemVersion"])[1])' \
        "$APPCAST" 2>/dev/null)"
    ARCHIVE_LENGTH="$(stat -f%z "$ARCHIVE")"

    [[ "$FEED_BUILD" == "$BUILD_NUMBER" ]] \
        || fail "the feed build number does not match VERSION."
    [[ "$FEED_MARKETING" == "$MARKETING_VERSION" ]] \
        || fail "the feed marketing version does not match VERSION."
    [[ "$FEED_URL" == "$EXPECTED_DOWNLOAD_URL" ]] \
        || fail "the feed enclosure URL does not match the release tag."
    [[ "$FEED_LENGTH" == "$ARCHIVE_LENGTH" ]] \
        || fail "dist/Louppe.zip changed after the feed was generated."
    [[ -n "$FEED_SIGNATURE" ]] || fail "the release archive has no EdDSA signature."
    [[ "$MINIMUM_SYSTEM" == "$(plist_value "$EXTRACTED_APP" LSMinimumSystemVersion)" ]] \
        || fail "the feed minimum macOS version does not match the app."
    if $PUBLISHING; then
        "$SPARKLE_TOOLS/sign_update" \
            --account "$ACCOUNT" \
            --verify "$ARCHIVE" "$FEED_SIGNATURE"
    fi
fi

echo "Release preflight passed for Louppe $MARKETING_VERSION ($BUILD_NUMBER)."
