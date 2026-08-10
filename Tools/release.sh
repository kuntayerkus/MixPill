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

# ── Keep the checked-in version honest ─────────────────────────────────────
#
# `xcodebuild MARKETING_VERSION=…` only affects this archive, so project.yml
# kept whatever it was last edited to say — which is how a 3.1.0 release
# shipped while the repository, and therefore every developer build, still
# claimed 3.0.0. The build number is bumped too: Sparkle compares
# CFBundleVersion, and two releases sharing "1" are indistinguishable to it.
echo "▸ Stamping version $VERSION into project.yml"
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$ROOT/project.yml" | tr -dc '0-9')
NEXT_BUILD=$(( ${CURRENT_BUILD:-0} + 1 ))
/usr/bin/sed -i '' \
    -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" \
    "$ROOT/project.yml"
echo "  marketing $VERSION, build $NEXT_BUILD"

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
    CURRENT_PROJECT_VERSION="$NEXT_BUILD" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    ENABLE_HARDENED_RUNTIME=YES \
    | grep -E "error:|warning:|BUILD" || true

APP="$BUILD/$APP_NAME.xcarchive/Products/Applications/$APP_NAME.app"
if [ ! -d "$APP" ]; then
    echo "✗ Archive did not produce $APP" >&2
    exit 1
fi

# ── Re-sign Sparkle's nested helpers ───────────────────────────────────────
#
# Sparkle ships as a binary framework through SPM, and the executables
# buried inside it — Autoupdate, Updater.app and two XPC services — arrive
# ad-hoc signed. Xcode signs inside-out, but only over code it built, so
# those keep their ad-hoc signatures and notarization rejects the whole
# submission with "The binary is not signed with a valid Developer ID
# certificate" and "The signature does not include a secure timestamp".
#
# They have to be signed innermost-first: signing a container seals whatever
# is inside it, so any later change to nested code invalidates the seal
# above it.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
    echo "▸ Re-signing Sparkle's nested code"
    for nested in \
        "$SPARKLE/Versions/B/XPCServices/Downloader.xpc" \
        "$SPARKLE/Versions/B/XPCServices/Installer.xpc" \
        "$SPARKLE/Versions/B/Updater.app" \
        "$SPARKLE/Versions/B/Autoupdate" \
        "$SPARKLE"
    do
        [ -e "$nested" ] || continue
        codesign --force --timestamp --options runtime \
            --sign "$IDENTITY" "$nested"
    done

    # Re-sealing the framework invalidates the app's own signature, so the
    # outer bundle is signed again on top.
    echo "▸ Re-signing the app over the updated framework"
    codesign --force --timestamp --options runtime \
        --entitlements "$ROOT/Resources/MixPill.entitlements" \
        --sign "$IDENTITY" "$APP"
fi

# ── The update key must be right before anything else is worth doing ───────
#
# generate_appcast signs an update only when the archived app's
# SUPublicEDKey matches the private key in the keychain. When it does not,
# it writes an *unsigned* entry and says nothing — and Sparkle then refuses
# that update on every machine. Catching it here costs a second; catching
# it after publishing costs a release.
echo "▸ Checking the Sparkle key"
EMBEDDED_KEY=$(plutil -extract SUPublicEDKey raw "$APP/Contents/Info.plist" 2>/dev/null || echo "")
KEYCHAIN_KEY=$("$ROOT/.spm/artifacts/sparkle/Sparkle/bin/generate_keys" -p 2>/dev/null | tr -d '[:space:]')
if [ -z "$EMBEDDED_KEY" ] || [ "$EMBEDDED_KEY" != "$KEYCHAIN_KEY" ]; then
    echo "✗ SUPublicEDKey in the built app does not match the signing key." >&2
    echo "  app:      ${EMBEDDED_KEY:-<missing>}" >&2
    echo "  keychain: ${KEYCHAIN_KEY:-<none>}" >&2
    echo "  Updates built from this would be published unsigned and rejected." >&2
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

# `notarytool submit --wait` exits 0 even when the verdict is Invalid, so
# the status has to be read out of its output. Without this the script
# happily staples nothing and produces a DMG Gatekeeper will refuse.
notarize() {
    local target="$1"
    local output
    output=$(xcrun notarytool submit "$target" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)
    echo "$output"
    if ! grep -q "status: Accepted" <<<"$output"; then
        local submission
        submission=$(grep -m1 "id:" <<<"$output" | awk '{print $2}')
        echo "✗ Apple rejected $(basename "$target"). Reasons:" >&2
        [ -n "$submission" ] && xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" >&2
        exit 1
    fi
}

notarize "$ZIP" 

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
notarize "$DMG"
xcrun stapler staple "$DMG"

# ── Sparkle feed ───────────────────────────────────────────────────────────
#
# Generated here rather than left as a printed instruction. The feed lives
# in the repository and `SUFeedURL` points straight at it on raw.github —
# so a release whose appcast never gets written is a release nobody's
# installed copy will ever see. That is exactly what happened to 3.1.0:
# the DMG shipped and appcast.xml was never committed, leaving automatic
# updates answering 404 for every existing install.
APPCAST="$ROOT/appcast.xml"
GENERATE_APPCAST="$ROOT/.spm/artifacts/sparkle/Sparkle/bin/generate_appcast"
echo "▸ Updating the Sparkle appcast"

# The zip exists only to hand the app to the notary service; the disk image
# is what gets published. generate_appcast scans this whole directory and
# refuses the entire run — writing no feed at all — when two archives carry
# the same bundle version: "Duplicate updates are not supported." So the
# notarization vehicle goes away before the feed is built.
rm -f "$ZIP"
"$GENERATE_APPCAST" --download-url-prefix \
    "https://github.com/kuntayerkus/MixPill/releases/download/v$VERSION/" \
    -o "$APPCAST" "$BUILD"

# generate_appcast writes an *unsigned* entry without complaining when the
# key does not match, and Sparkle then rejects the update on every machine.
# The key was verified above, so an unsigned entry here means something
# else went wrong — either way it must not be published.
if ! grep -q "sparkle:edSignature" "$APPCAST"; then
    echo "✗ appcast.xml has no sparkle:edSignature — Sparkle would reject this update." >&2
    exit 1
fi

SIZE=$(du -h "$DMG" | cut -f1)
echo
echo "✓ $DMG ($SIZE)"
echo "✓ $APPCAST signed"
echo
echo "To publish:"
echo "  gh release create v$VERSION \"$DMG\" --title \"MixPill $VERSION\" --generate-notes"
echo "  git add appcast.xml project.yml && git commit -m \"Release $VERSION\""
echo "  git push"
echo
echo "Pushing appcast.xml to main is what makes the update live — the DMG on"
echo "its own updates nobody."
