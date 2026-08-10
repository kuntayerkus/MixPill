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

echo "Building so the compiler emits fresh .stringsdata…"
xcodebuild -project "$root/MixPill.xcodeproj" -scheme MixPill \
    -configuration Debug -derivedDataPath "$derived" build >/dev/null

data=$(find "$derived" -name '*.stringsdata' -path '*MixPill.build*')
if [ -z "$data" ]; then
    echo "No .stringsdata produced — is SWIFT_EMIT_LOC_STRINGS still set?" >&2
    exit 1
fi

# shellcheck disable=SC2086
"$tool" sync "$catalog" --stringsdata $data

printf 'Catalog now holds %s keys.\n' \
    "$(python3 -c "import json,sys; print(len(json.load(open('$catalog'))['strings']))")"
