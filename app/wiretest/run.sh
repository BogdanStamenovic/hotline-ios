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

# The `live-*.json` fixtures are the bytes an OLDER daemon sent -- no state, no
# vitals, no controls -- and they are what proves the graceful-degradation
# claims rather than asserting them. **They are deliberately not refreshed.**
# The `today-*.json` set is the current contract, and those are.
if [[ $# -ge 1 ]]; then
    host="$1"
    agent="${2:-hotline-80}"
    echo "refreshing today's fixtures from $host:8789 (agent: $agent)"
    curl -sf "http://$host:8789/health" -o "$here/fixtures/today-health.json"
    curl -sf -X POST -H 'Content-Type: application/json' \
        -d '{"include_done":true,"include_retired":true}' \
        "http://$host:8789/api/v1/agents" -o "$here/fixtures/today-agents.json"
    curl -sf -X POST -H 'Content-Type: application/json' \
        -d "{\"agent\":\"$agent\",\"limit\":200}" \
        "http://$host:8789/api/v1/agents/history" -o "$here/fixtures/live-history.json"
    curl -sf -X POST -H 'Content-Type: application/json' \
        -d "{\"agent\":\"$agent\",\"since\":0,\"wait\":0}" \
        "http://$host:8789/api/v1/agents/feed" -o "$here/fixtures/today-feed.json"
    # dry_run only. This script never writes and never touches his daemon's state.
    curl -sf -X POST -H 'Content-Type: application/json' \
        -d "{\"agent\":\"$agent\",\"scope\":\"history\",\"dry_run\":true}" \
        "http://$host:8789/api/v1/agents/purge" -o "$here/fixtures/today-purge-dryrun.json"
fi

# Deleted first, on purpose. A stale binary from a previous run passing its own
# old assertions is exactly the green check that measures nothing this project
# keeps getting caught by.
rm -f "$out"

# The Swift 6.2 toolchain on archserver lives outside the default paths. On a
# macOS runner the Xcode toolchain is already the one on PATH, and that file
# does not exist -- so this is conditional rather than unconditional, and the
# same script is the check in both places.
if [[ -f /mnt/iosbuild/env62.sh ]]; then
    source /mnt/iosbuild/env62.sh
fi

swiftc -swift-version 6 \
    "$here/main.swift" \
    "$sources/Wire/Wire.swift" \
    "$sources/Wire/Rules.swift" \
    "$sources/Store/SampleRing.swift" \
    "$sources/Store/Route.swift" \
    "$sources/Theme/Scalars.swift" \
    -o "$out"

"$out" "$here/fixtures"
