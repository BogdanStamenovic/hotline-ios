#!/usr/bin/env python3
"""Warn Bogdan before the free provisioning profile expires.

SPEC 6 asks for this. Free profiles last 7 days and the app stops launching
the moment one lapses, so the failure mode is silent: nothing breaks here, the
icon just stops working in his pocket.

It QUERIES Apple rather than hardcoding a date. The date everyone had written
down (1 Sep 22:53) was derived from when the *device* was registered; the
profile's real clock starts when the app is *installed*, and Apple reports
2 Sep 04:16. Deriving it locally is how that drifted, so this asks the
authority instead.
"""
import argparse
import re
import subprocess
import sys
from datetime import datetime, timedelta

XTOOL = "/mnt/iosbuild/toolchain/xtool.AppImage"
PAGE = "/home/bodas/.claude/bin/hotline-page"
BUNDLE = "dev.stamenovic.hotlinecall"
INSTALL_CMD = "curl -fsSL http://100.72.2.62:8790/get.sh | bash"


def profiles():
    """Every profile Apple currently holds, as (name, expiry, entitlements)."""
    out = subprocess.run([XTOOL, "ds", "profiles", "list"],
                         capture_output=True, text=True, timeout=180)
    if out.returncode != 0:
        raise SystemExit(f"xtool ds profiles list failed:\n{out.stderr.strip()}")

    found, cur = [], {}
    for line in out.stdout.splitlines():
        if line.startswith("- id:"):
            if cur:
                found.append(cur)
            cur = {"id": line.split(":", 1)[1].strip()}
        elif m := re.match(r"\s*expiration date:\s*(.+)", line):
            # Apple via xtool: "02/09/2026, 4:16 AM" -- day first.
            cur["expiry"] = datetime.strptime(m.group(1).strip(), "%d/%m/%Y, %I:%M %p")
        elif m := re.match(r"\s*profile state:\s*(.+)", line):
            cur["state"] = m.group(1).strip()
        elif "application-identifier" in line:
            cur["ents"] = line.strip()
    if cur:
        found.append(cur)
    return found


def page(argv, dry):
    if dry:
        print("WOULD PAGE:")
        for a in argv[1:]:
            print("   ", a.replace("\n", "\n    "))
        return
    subprocess.run(argv, timeout=180)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--warn-days", type=float, default=2.0,
                    help="page him when fewer than this many days remain")
    ap.add_argument("--check", action="store_true",
                    help="print status and exit without paging")
    ap.add_argument("--dry-run", action="store_true",
                    help="print the page that would be sent instead of sending it")
    args = ap.parse_args()

    ours = [p for p in profiles()
            if BUNDLE in p.get("ents", "") and p.get("state") == "ACTIVE"
            and "expiry" in p]
    if not ours:
        print("no ACTIVE profile for", BUNDLE, file=sys.stderr)
        # Not an error to swallow: no profile means the app is already dead.
        if not args.check:
            page([PAGE, "--no-wait", "--source", "the hotline iOS build",
                  f"Apple has no active provisioning profile for the app "
                  f"any more, so it will not launch. Re-sign from the "
                  f"laptop:\n\n    {INSTALL_CMD}"], args.dry_run)
        return 1

    soonest = min(ours, key=lambda p: p["expiry"])
    left = soonest["expiry"] - datetime.now()
    hours = left.total_seconds() / 3600
    print(f"profile {soonest['id']} expires {soonest['expiry']:%d/%m/%Y %H:%M} "
          f"({hours:.1f} h / {hours/24:.2f} d left)")

    if args.check:
        return 0
    if left > timedelta(days=args.warn_days):
        return 0

    when = f"{soonest['expiry']:%A %d %B at %H:%M}"
    page([PAGE, "--no-wait", "--source", "the hotline iOS build",
                    f"The app's signing profile expires {when} -- about "
                    f"{hours:.0f} hours from now. After that it stops launching "
                    f"on your phone until it is re-signed.\n\nOn the laptop, "
                    f"phone plugged in and unlocked:\n\n    {INSTALL_CMD}",
                    "--context",
                    "This is the 7-day free-provisioning clock, not a fault. "
                    "Re-running that command renews it for another 7 days; the "
                    "download resumes if your link drops. Nothing needs doing on "
          "the Arch box."], args.dry_run)
    return 0


if __name__ == "__main__":
    sys.exit(main())
