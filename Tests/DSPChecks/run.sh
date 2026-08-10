#!/bin/sh
#
# Checks for the parts of MixPill that are pure value logic — the ring
# buffer, the channel strip's filter chain, the routing pair id, the
# fader and meter scales, and preset migration. No Xcode target: none of
# these files touch XPC or the HAL, so a standalone binary exercises them
# directly and runs in about a second.
#
#   Tests/DSPChecks/run.sh          # run the checks
#   Tests/DSPChecks/run.sh --guard  # ...under guard malloc
#
# The guard-malloc run matters: the two bugs these checks were written for
# were heap overruns, and an overrun does not reliably crash on its own.
# libgmalloc turns it into an immediate, unmissable abort.

set -e
root=$(cd "$(dirname "$0")/../.." && pwd)
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

swiftc -O -swift-version 6 -o "$out/dspchecks" \
    "$root/Core/RingBufferManager.swift" \
    "$root/Core/ChannelDSP.swift" \
    "$root/Core/RealtimeSupport.swift" \
    "$root/Core/CoreLog.swift" \
    "$root/Shared/CoreIdentifiers.swift" \
    "$root/Utilities/AudioScale.swift" \
    "$root/Models/PresetModel.swift" \
    "$root/Tests/DSPChecks/Contracts.swift" \
    "$root/Tests/DSPChecks/main.swift"

if [ "$1" = "--guard" ]; then
    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$out/dspchecks"
else
    "$out/dspchecks"
fi
