#!/bin/bash
#
# Builds, signs, notarizes, staples and packages MixPill for release.
#
#   Tools/release.sh 3.1.0
#
# Everything between "it builds on my machine" and "a stranger can double
# click it" lives here. Gatekeeper rejects an un-notarized download outright,
# so skipping any of these steps means most people never get past the first
# dialog.
#
# Credentials come from a keychain profile, never from this file:
#
#   xcrun notarytool store-credentials MixPillNotary \
#       --apple-id you@example.com --team-id CL4KZ4JZDQ --password <app-specific>
#
# Sparkle's appcast is signed separately with the private EdDSA key held in
# your login keychain (see the note at the end).

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: Tools/release.sh <marketing-version>   e.g. Tools/release.sh 3.1.0" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
APP_NAME="MixPill"
TEAM_ID="CL4KZ4JZDQ"
NOTARY_PROFILE="${MIXPILL_NOTARY_PROFILE:-MixPillNotary}"
IDENTITY="${MIXPILL_SIGN_IDENTITY:-Developer ID Application}"

echo "▸ Cleaning $BUILD"
rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "▸ Regenerating the Xcode project"
cd "$ROOT"
xcodegen generate >/dev/null

# ── Archive ────────────────────────────────────────────────────────────────
# Release configuration, Developer ID identity, hardened runtime on. The
# hardened runtime is not optional: notarization refuses anything without it.
echo "▸ Archiving $APP_NAME $VERSION"
xcodebuild archive \
    -project "$ROOT/MixPill.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -archivePath "$BUILD/$APP_NAME.xcarchive" \
    -clonedSourcePackagesDirPath "$ROOT/.spm" \
    MARKETING_VERSION="$VERSION" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    | grep -E "error:|warning:|BUILD" || true

APP="$BUILD/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "✗ Archive did not produce $APP" >&2
    exit 1
fi

# ── Verify the signature before spending a notarization round trip ─────────
echo "▸ Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP"
# Nested code — the XPC service and Sparkle's framework and XPC helpers —
# must each be validly signed. `--deep` verification catches a nested bundle
# that got missed; note that signing with --deep is a different thing and is
# discouraged, which is why the build signs inside-out instead.

# ── Notarize ───────────────────────────────────────────────────────────────
ZIP="$BUILD/$APP_NAME-$VERSION.zip"
echo "▸ Submitting to Apple for notarization (this takes a few minutes)"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

echo "▸ Stapling the ticket"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

# Gatekeeper's own verdict, which is what the user's Mac will do.
echo "▸ Gatekeeper assessment"
spctl --assess --type execute --verbose=2 "$APP"

# ── Package ────────────────────────────────────────────────────────────────
DMG="$BUILD/$APP_NAME-$VERSION.dmg"
STAGE="$BUILD/dmg"
echo "▸ Building $DMG"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The Applications symlink is the whole install instruction: drag left to
# right. Anything more elaborate is a design project, not a requirement.
ln -s /Applications "$STAGE/Applications"

hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG" >/dev/null

# The disk image is signed too, so the download itself is trusted before it
# is even opened.
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ $DMG ($SIZE)"
echo
echo "Next, for the Sparkle feed:"
echo "  1. .spm/artifacts/sparkle/Sparkle/bin/generate_appcast \"$BUILD\""
echo "     — signs the update with your private EdDSA key and writes appcast.xml"
echo "  2. Confirm SUPublicEDKey in Resources/Info.plist matches that key pair."
echo "  3. Upload the DMG and appcast.xml to the host behind SUFeedURL."
echo
echo "Until SUPublicEDKey holds a real key, do not publish: unsigned updates"
echo "are refused by Sparkle, which is the behaviour you want."
