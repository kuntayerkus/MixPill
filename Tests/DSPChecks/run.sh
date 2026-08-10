#!/bin/sh
#
# Checks for the core DSP primitives — the ring buffer and the channel
# strip's filter chain — compiled straight against the engine sources.
# No Xcode target: these classes are plain Swift with no XPC, no HAL and
# no ScreenCaptureKit, so a standalone binary exercises them directly.
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
    "$root/Tests/DSPChecks/main.swift"

if [ "$1" = "--guard" ]; then
    DYLD_INSERT_LIBRARIES=/usr/lib/libgmalloc.dylib "$out/dspchecks"
else
    "$out/dspchecks"
fi
