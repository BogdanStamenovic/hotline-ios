#!/usr/bin/env python3
"""Print the UDID of the best iPhone simulator on this machine.

Hardcoding `name=iPhone 16` in the workflow is how a CI job starts failing
silently six months from now when the runner image rolls forward and that
device is gone. This asks what is actually installed.

Preference order: newest iOS runtime that is at least 18.0 (the app's
deployment target), then a plain numbered iPhone over a Pro/Max/SE/mini --
the plain one is the size the app was designed against and the cheapest to
render.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys

MIN_IOS = (18, 0)


def main() -> int:
    raw = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"],
        capture_output=True, text=True, check=True,
    ).stdout
    devices = json.loads(raw)["devices"]

    best = None
    seen: list[str] = []
    for runtime, devs in devices.items():
        m = re.search(r"iOS[-.](\d+)[-.](\d+)", runtime)
        if not m:
            continue
        version = (int(m.group(1)), int(m.group(2)))
        for dev in devs:
            if not dev.get("isAvailable"):
                continue
            name = dev["name"]
            if not name.startswith("iPhone"):
                continue
            seen.append(f"{name} (iOS {version[0]}.{version[1]})")
            if version < MIN_IOS:
                continue
            plain = not any(w in name for w in ("Pro", "Max", "SE", "mini", "Plus"))
            rank = (version, plain, name)
            if best is None or rank > best[0]:
                best = (rank, dev, runtime)

    if best is None:
        print("no iPhone simulator with iOS >= %d.%d" % MIN_IOS, file=sys.stderr)
        print("what this image does have:", file=sys.stderr)
        for s in sorted(set(seen)):
            print("  " + s, file=sys.stderr)
        return 1

    print(best[1]["udid"])
    print(f"picked {best[1]['name']} on {best[2]}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
