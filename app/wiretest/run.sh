#!/usr/bin/env bash
# The only way to execute any of this app's code on the box it is built on.
#
# `Wire/Wire.swift`, `Wire/Rules.swift` and `Store/SampleRing.swift` import
# Foundation and nothing else, so they compile and RUN natively on Linux with
# the same toolchain that builds the ipa. Everything in them was put there
# deliberately: the decode contract, the pending reconciliation that fixes
# bug 3, and every readout's formatting.
#
#   app/wiretest/run.sh              run against the checked-in fixtures
#   app/wiretest/run.sh 100.72.2.62  refresh the fixtures from a live daemon first
#
# Refreshing only ever issues reads (`/health`, `/api/v1/agents`,
# `/api/v1/conversations`). It never writes and never touches his running
# daemon's state.
# `-u` is deliberately absent: env62.sh appends to LD_LIBRARY_PATH, which is
# unset on a clean shell.
set -eo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sources="$here/../HotlineCall/Sources/HotlineCall"
out="${TMPDIR:-/tmp}/hotline-wiretest"

if [[ $# -ge 1 ]]; then
    host="$1"
    echo "refreshing fixtures from $host:8789"
    curl -sf "http://$host:8789/health" -o "$here/fixtures/live-health.json"
    curl -sf -X POST -H 'Content-Type: application/json' -d '{}' \
        "http://$host:8789/api/v1/agents" -o "$here/fixtures/live-agents.json"
    curl -sf -X POST -H 'Content-Type: application/json' -d '{}' \
        "http://$host:8789/api/v1/conversations" -o "$here/fixtures/live-conversations.json"
fi

# Deleted first, on purpose. A stale binary from a previous run passing its own
# old assertions is exactly the green check that measures nothing this project
# keeps getting caught by.
rm -f "$out"

source /mnt/iosbuild/env62.sh
swiftc -swift-version 6 \
    "$here/main.swift" \
    "$sources/Wire/Wire.swift" \
    "$sources/Wire/Rules.swift" \
    "$sources/Store/SampleRing.swift" \
    "$sources/Store/Route.swift" \
    "$sources/Theme/Scalars.swift" \
    -o "$out"

"$out" "$here/fixtures"
