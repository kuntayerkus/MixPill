#!/bin/sh
#
# Pulls every user-facing string out of the built sources and merges it
# into Resources/Localizable.xcstrings.
#
#   Tools/sync-strings.sh
#
# Xcode does this automatically when you build in the IDE. Running a
# command-line build does not, so this exists to keep the catalog honest
# from a terminal and from CI — a string that never reaches the catalog
# can never be translated.
#
# Keys are derived from the SwiftUI literals themselves, so adding UI text
# needs no separate registration step: write `Text("…")`, run this, and the
# key appears for translators.

set -e
root=$(cd "$(dirname "$0")/.." && pwd)
catalog="$root/Resources/Localizable.xcstrings"
derived="$root/DerivedData"
tool="$(xcode-select -p)/usr/bin/xcstringstool"

if [ ! -x "$tool" ]; then
    echo "xcstringstool not found at $tool" >&2
    exit 1
fi

# Clear stale extraction output first.
#
# The sync collects every .stringsdata under the derived data directory,
# and an incremental build leaves the files from previous builds in place.
# A string that has since been reworded therefore stays in the catalog
# forever on a developer's machine, while CI — which always starts clean —
# produces a catalog without it. The two then disagree permanently.
find "$derived" -name '*.stringsdata' -delete 2>/dev/null || true

echo "Building so the compiler emits fresh .stringsdata…"
# Signing is irrelevant to string extraction, and requiring it would make
# this unusable anywhere without a certificate — CI included.
xcodebuild -project "$root/MixPill.xcodeproj" -scheme MixPill \
    -configuration Debug -derivedDataPath "$derived" \
    -clonedSourcePackagesDirPath "$root/.spm" \
    CODE_SIGNING_ALLOWED=NO build >/dev/null

data=$(find "$derived" -name '*.stringsdata' -path '*MixPill.build*')
if [ -z "$data" ]; then
    echo "No .stringsdata produced — is SWIFT_EMIT_LOC_STRINGS still set?" >&2
    exit 1
fi

# shellcheck disable=SC2086
"$tool" sync "$catalog" --stringsdata $data

printf 'Catalog now holds %s keys.\n' \
    "$(python3 -c "import json,sys; print(len(json.load(open('$catalog'))['strings']))")"
