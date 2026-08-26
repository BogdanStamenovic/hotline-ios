#!/usr/bin/env python3
"""Frame timings out of a simctl recording, with no ffmpeg and no dependencies.

`xcrun simctl io <udid> recordVideo` writes one sample per composited frame, so
the mp4's own sample table holds a run-length list of per-frame durations in
`mdhd` timescale units (`stts`). Reading it back gives the interval between
frames that actually reached the screen.

Why this exists at all: the Apple-native answer is XCTOSSignpostMetric's hitch
metrics, and those only report if the view being scrolled is UIScrollView
backed and emits the OS signposts. This app drives most of its motion from a
custom recognizer and hand-rolled layers, so the signposts may never fire. This
measure has no such precondition -- it counts what reached the screen.

WHAT THIS IS NOT: a render timeline. It is a *capture* timeline, and the
difference is the whole reason this file was rewritten on 2026-08-26.

Two ways the naive reading of it lies, both observed in run 32923724565:

1. A static screen composites no frames, so "nothing moved for 20 seconds"
   arrives as a single 20-second frame interval. Scored as lateness, one idle
   gap out-weighed every real stall in the run.

2. The recorder timestamps capture, not vsync, and it quantises to the media
   timescale. A flawless 60fps stream comes back as intervals alternating a
   tick either side of 16.67ms. `sum(max(0, d - budget))` rectifies that
   zero-mean jitter into pure "hitch": feed it a synthetic perfect 60fps
   stream with +-1 tick of jitter and the old code returned 49 ms/s, five
   times Apple's user-visible threshold, for an app that never dropped
   anything. `--self-test` asserts that exact case, so this cannot come back.

So: idle is separated rather than scored, and only intervals past
`--late-factor` budgets count, which is far outside the jitter band. The
headline number is dropped frames, because a missed frame cannot be produced
by timestamp noise.

Still true, and still the honest limit: this cannot tell you *why* a long
interval happened, it cannot see a frame composited identically twice, and on
a CI runner the simulator renders in software, so some of what it measures is
the runner rather than the app. It is a floor on jank, not a ceiling, and it
cannot by itself attribute jank to your code.

Usage: frametimes.py video.mp4 [--json out.json] [--budget-hz 60]
                     [--idle-ms 250] [--late-factor 1.5] [--self-test]
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


def analyse(ms: list[float], budget: float, idle_ms: float, late_factor: float) -> dict:
    """Split intervals into idle / on-time / late, and score only the late ones."""
    idle = [d for d in ms if d > idle_ms]
    active = [d for d in ms if d <= idle_ms]
    if not active:
        return {"error": "every interval was longer than the idle threshold"}

    late_over = budget * late_factor
    late = [d for d in active if d > late_over]

    # A missed frame cannot be timestamp noise: at 1.5 budgets the interval is
    # already seven ticks outside the observed jitter band. Round to the nearest
    # whole frame the display would have shown.
    missed = sum(round(d / budget) - 1 for d in late)
    hitch_ms = sum(d - budget for d in late)
    active_s = sum(active) / 1000.0
    drop_pct = missed / (missed + len(active)) * 100.0

    srt = sorted(active)

    def pct(p: float) -> float:
        return srt[min(len(srt) - 1, int(round(p / 100.0 * (len(srt) - 1))))]

    return {
        "presented_frames": len(active),
        "active_s": round(active_s, 3),
        "median_ms": round(pct(50), 2),
        "effective_fps": round(len(active) / active_s, 2) if active_s else 0,
        "frame_ms": {
            "p50": round(pct(50), 2),
            "p90": round(pct(90), 2),
            "p99": round(pct(99), 2),
            "max": round(max(active), 2),
        },
        "late_intervals": len(late),
        "dropped_frames": missed,
        "dropped_frame_pct": round(drop_pct, 2),
        "hitch_time_ms": round(hitch_ms, 2),
        "hitch_ratio_ms_per_s": round(hitch_ms / active_s, 2) if active_s else 0,
        "idle_gaps": {
            "count": len(idle),
            "total_s": round(sum(idle) / 1000.0, 2),
            "longest_s": round(max(idle) / 1000.0, 2) if idle else 0,
        },
        # Scored on dropped frames, not on hitch time: hitch time still carries
        # some jitter, the drop count carries none.
        "verdict": (
            "good" if drop_pct < 1 else "marginal" if drop_pct < 5 else "hitchy"
        ),
    }


def self_test(budget: float, late_factor: float) -> int:
    """A perfect 60fps stream with the recorder's own jitter must score clean."""
    import itertools

    tick = 1000.0 / 600.0
    jittered = list(
        itertools.islice(itertools.cycle([budget - tick, budget + tick]), 6000)
    )
    r = analyse(jittered, budget, 250.0, late_factor)
    ok = r["dropped_frames"] == 0 and r["verdict"] == "good"
    mean = sum(jittered) / len(jittered)
    print(f"self-test: synthetic {1000 / mean:.1f} fps, +-1 tick of capture jitter")
    print(f"  dropped_frames={r['dropped_frames']}  verdict={r['verdict']}")
    print(f"  {'PASS' if ok else 'FAIL -- jitter is being scored as hitch again'}")

    # And a stream that genuinely drops every other frame must NOT score clean.
    dropping = [budget * 2] * 3000
    r2 = analyse(dropping, budget, 250.0, late_factor)
    ok2 = r2["dropped_frames"] == 3000 and r2["verdict"] == "hitchy"
    print("self-test: synthetic 30fps against a 60fps budget")
    print(f"  dropped_frames={r2['dropped_frames']}  verdict={r2['verdict']}")
    print(f"  {'PASS' if ok2 else 'FAIL -- real drops are not being caught'}")
    return 0 if (ok and ok2) else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", nargs="?")
    ap.add_argument("--json", dest="json_out")
    ap.add_argument("--budget-hz", type=float, default=60.0)
    ap.add_argument(
        "--idle-ms",
        type=float,
        default=250.0,
        help="intervals longer than this are the screen sitting still, not a "
        "dropped frame; reported separately rather than scored",
    )
    ap.add_argument(
        "--late-factor",
        type=float,
        default=1.5,
        help="an interval counts as late past this many budgets; the default "
        "sits far outside the recorder's timestamp jitter",
    )
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()

    budget = 1000.0 / args.budget_hz
    if args.self_test:
        return self_test(budget, args.late_factor)
    if not args.video:
        ap.error("a video is required unless --self-test is given")

    data = Path(args.video).read_bytes()
    timescale, stts = find_video_track(data)
    ticks = durations(data, stts)
    if len(ticks) < 2:
        print(f"only {len(ticks)} frames -- nothing to measure", file=sys.stderr)
        return 2

    ms = [t * 1000.0 / timescale for t in ticks]
    report = {
        "frames": len(ms),
        "duration_s": round(sum(ms) / 1000.0, 3),
        "timescale": timescale,
        "budget_ms": round(budget, 3),
        "idle_ms": args.idle_ms,
        **analyse(ms, budget, args.idle_ms, args.late_factor),
        "caveats": [
            "idle gaps are excluded from the score and reported separately",
            "a CI runner renders the simulator in software, so some of this "
            "is the runner and not the app",
            "a floor on jank, not a ceiling: it cannot say why a frame was late",
        ],
    }

    print(json.dumps(report, indent=2))
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(report, indent=2))

    active = [d for d in ms if d <= args.idle_ms]
    print("\nframe-interval histogram, active only (ms):", file=sys.stderr)
    buckets = [(0, 8), (8, 17), (17, 25), (25, 34), (34, 50), (50, 100), (100, 1e9)]
    for lo, hi in buckets:
        n = sum(1 for d in active if lo <= d < hi)
        if not n:
            continue
        label = f"{lo:>4.0f}-{hi:<5.0f}" if hi < 1e9 else f"{lo:>4.0f}+     "
        bar = "#" * min(60, max(1, round(n / len(active) * 60)))
        print(f"  {label} {n:>6}  {bar}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
