#!/usr/bin/env python3
"""Frame timings out of a simctl recording, with no ffmpeg and no dependencies.

`xcrun simctl io <udid> recordVideo` writes one sample per composited frame, so
the mp4's own sample table *is* the render timeline: the `stts` atom holds a
run-length list of per-frame durations in `mdhd` timescale units. Reading it
back gives the interval between consecutive presented frames, which is the
thing a "does it drop frames" question is actually asking about.

Why this exists at all: the Apple-native answer is XCTOSSignpostMetric's
hitch metrics, and those only report if the view being scrolled is UIScrollView
backed and emits the OS signposts. This app drives most of its motion from a
custom recognizer and hand-rolled layers, so the signposts may never fire. This
measure has no such precondition -- it counts what reached the screen.

What it cannot tell you: *why* a long interval happened, and it cannot see a
frame that was composited identically twice. It is a floor on jank, not a
ceiling.

Usage: frametimes.py video.mp4 [--json out.json] [--budget-hz 60]
"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path


def walk(data: bytes, start: int, end: int, path: str = ""):
    """Yield (type, payload_start, payload_end, path) for every atom in a range."""
    pos = start
    while pos + 8 <= end:
        (size,) = struct.unpack_from(">I", data, pos)
        atype = data[pos + 4 : pos + 8].decode("latin-1")
        header = 8
        if size == 1:
            (size,) = struct.unpack_from(">Q", data, pos + 8)
            header = 16
        elif size == 0:
            size = end - pos
        if size < header or pos + size > end:
            break
        yield atype, pos + header, pos + size, path + "/" + atype
        pos += size


CONTAINERS = {"moov", "trak", "mdia", "minf", "stbl", "edts", "udta"}


def find_video_track(data: bytes):
    """Return (timescale, stts_payload_range) for the first video track."""
    top = list(walk(data, 0, len(data)))
    moov = next((a for a in top if a[0] == "moov"), None)
    if moov is None:
        raise SystemExit("no moov atom: not an mp4 this parser understands")

    def descend(lo, hi, want, acc):
        for atype, plo, phi, _ in walk(data, lo, hi):
            if atype == want:
                acc.append((plo, phi))
            if atype in CONTAINERS:
                descend(plo, phi, want, acc)

    for _, tlo, thi, _ in [a for a in walk(data, moov[1], moov[2]) if a[0] == "trak"]:
        hdlrs: list[tuple[int, int]] = []
        descend(tlo, thi, "hdlr", hdlrs)
        kinds = {data[lo + 8 : lo + 12].decode("latin-1") for lo, _ in hdlrs}
        if "vide" not in kinds:
            continue
        mdhds: list[tuple[int, int]] = []
        descend(tlo, thi, "mdhd", mdhds)
        sttss: list[tuple[int, int]] = []
        descend(tlo, thi, "stts", sttss)
        if not mdhds or not sttss:
            continue
        lo, _ = mdhds[0]
        version = data[lo]
        timescale = (
            struct.unpack_from(">I", data, lo + 4 + 8 + 8)[0]
            if version == 1
            else struct.unpack_from(">I", data, lo + 4 + 4 + 4)[0]
        )
        return timescale, sttss[0]
    raise SystemExit("no video track with both mdhd and stts")


def durations(data: bytes, stts: tuple[int, int]) -> list[int]:
    lo, hi = stts
    (count,) = struct.unpack_from(">I", data, lo + 4)
    out: list[int] = []
    pos = lo + 8
    for _ in range(count):
        if pos + 8 > hi:
            break
        n, dur = struct.unpack_from(">II", data, pos)
        out.extend([dur] * n)
        pos += 8
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--budget-hz", type=float, default=60.0)
    args = ap.parse_args()

    data = Path(args.video).read_bytes()
    timescale, stts = find_video_track(data)
    ticks = durations(data, stts)
    if len(ticks) < 2:
        print(f"only {len(ticks)} frames -- nothing to measure", file=sys.stderr)
        return 2

    ms = [t * 1000.0 / timescale for t in ticks]
    total_ms = sum(ms)
    budget = 1000.0 / args.budget_hz

    # Apple's own definition: a hitch is a frame that arrives later than it
    # should have, and hitch *time* is the excess, not the count. Anything at or
    # under one refresh interval is on time by construction.
    hitch_ms = sum(max(0.0, d - budget) for d in ms)
    ratio = (hitch_ms / total_ms * 1000.0) if total_ms else 0.0  # ms hitch / s

    srt = sorted(ms)

    def pct(p: float) -> float:
        return srt[min(len(srt) - 1, int(round(p / 100.0 * (len(srt) - 1))))]

    over2 = sum(1 for d in ms if d > budget * 2)
    over4 = sum(1 for d in ms if d > budget * 4)
    worst = max(ms)

    report = {
        "frames": len(ms),
        "duration_s": round(total_ms / 1000.0, 3),
        "timescale": timescale,
        "effective_fps": round(len(ms) / (total_ms / 1000.0), 2) if total_ms else 0,
        "budget_ms": round(budget, 3),
        "frame_ms": {
            "p50": round(pct(50), 2),
            "p90": round(pct(90), 2),
            "p99": round(pct(99), 2),
            "max": round(worst, 2),
        },
        "late_frames": {
            "over_1_budget": sum(1 for d in ms if d > budget * 1.5),
            "over_2_budgets": over2,
            "over_4_budgets": over4,
        },
        "hitch_time_ms": round(hitch_ms, 2),
        "hitch_ratio_ms_per_s": round(ratio, 2),
        # Apple's shipping guidance for scroll: under 5 ms hitch per second is
        # good, over 10 ms/s is a user-visible problem.
        "verdict": (
            "good" if ratio < 5 else "marginal" if ratio < 10 else "hitchy"
        ),
    }

    print(json.dumps(report, indent=2))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(report, indent=2))

    print("\nframe-interval histogram (ms):", file=sys.stderr)
    buckets = [(0, 8), (8, 17), (17, 25), (25, 34), (34, 50), (50, 100), (100, 1e9)]
    for lo, hi in buckets:
        n = sum(1 for d in ms if lo <= d < hi)
        if not n:
            continue
        label = f"{lo:>4.0f}-{hi:<5.0f}" if hi < 1e9 else f"{lo:>4.0f}+     "
        bar = "#" * min(60, max(1, round(n / len(ms) * 60)))
        print(f"  {label} {n:>6}  {bar}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
