#!/usr/bin/env python3
"""A stand-in for `hotline-iosd`, so CI can drive the app without a tailnet.

The bytes are not invented. `app/wiretest/fixtures/` holds real captures from
the live daemon -- a roster of ten agents, and a 29-event history with three
phases, two outcomes and twenty-four tool calls -- and this serves those,
with three deliberate edits:

  * **timestamps are rebased onto now.** The capture is from 2026-08-25, and an
    app that renders "1d" everywhere shows none of the ticking-clock or
    relative-time motion that is the point of recording it.
  * **one agent is marked blocked.** The capture has none, and a blocked agent
    is the case the whole arrival choreography, the NEEDS YOU beat, the taller
    row and the cold auto-open exist for. `blocked: true` + `blockedSince` is
    all it takes -- `Agent.presence` puts blocked above every other state.
  * **the feed grows.** A real agent emits events while you watch it; a static
    fixture never moves. One synthetic tool call is released every few seconds,
    drawn from the captured ones, so the thread grows and the tool dot flashes
    on video instead of the screen being a still.

Everything else is the fixture, unmodified.

No auth: the app sends no `X-Hotline-Key` (grepped), so requiring one would
401 every call. The real daemon's key is optional and off by default too.

Long polls (`/agents/feed`, `/agents/roster-events`) take `wait` up to 25 s from
the client, whose HTTP timeout is 40 s. This replies in at most POLL_HOLD
seconds with `{"events": [], "cursor": <the since it was given>}`, which is
exactly what the real daemon does on an idle timeout -- just sooner, because a
CI run should not spend its life asleep.
"""

from __future__ import annotations

import copy
import json
import random
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FIXTURES = Path(__file__).resolve().parents[2] / "app" / "wiretest" / "fixtures"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8789

# Short enough that an idle poll does not stall the drive, long enough that the
# app is not hammering the stub in a tight loop.
POLL_HOLD = 2.5
# How often a new synthetic event is released onto the open channel's feed.
FEED_TICK = 4.0
# Which agent gets the blocked treatment. It is the one the UI test taps.
BLOCKED = "hotline-ios"

BOOT = time.time()
LOCK = threading.Lock()


def load(name: str):
    return json.loads((FIXTURES / name).read_text())


# --------------------------------------------------------------------------
# The captured bytes, rebased onto this run's clock.

HEALTH = load("today-health.json")
ROSTER = load("today-agents.json")
HISTORY = load("live-history.json")
FEED = load("today-feed.json")
PURGE = load("today-purge-dryrun.json")


def rebase(events, span=1800.0):
    """Spread the captured events across the `span` seconds before boot.

    The capture's own spacing is kept in proportion, so a tool call that took a
    long gap after the one before it still does. Only the origin moves.
    """
    if not events:
        return events
    ats = [e["at"] for e in events if "at" in e]
    lo, hi = min(ats), max(ats)
    width = max(hi - lo, 1.0)
    for e in events:
        if "at" in e:
            e["at"] = BOOT - span + (e["at"] - lo) / width * span
    return events


rebase(HISTORY["events"])
rebase(FEED["events"])


# --------------------------------------------------------------------------
# CI-only prose, so the drive can exercise the path that carries it.
#
# `live-history.json` is a capture from a daemon that did not store assistant
# prose, and it is **deliberately frozen** -- it is the only thing proving the
# app degrades gracefully when a field is absent, and `app/wiretest/run.sh`
# already had a bug once that quietly overwrote it. So it is not edited here.
# These events are synthesised, live in this stub, and touch no fixture.
#
# They attach to the FIRST phase that has an outcome and pointedly not to the
# second, so one screen shows both halves of the rule: where prose exists the
# outcome caption is suppressed as a duplicate of it, and where prose does not
# exist the outcome must still be drawn or the answer is lost outright. With no
# prose anywhere -- which is what every run before this one had -- the skip is a
# no-op and a green run says nothing about it either way.

_PROSE_LEAD = "Before I touch anything: here is what the run is actually for."

_PROSE_BODY = (
    "This paragraph exists so a screenshot can prove the prose arrives whole.\n\n"
    "Until 27 August the server stored an assistant answer only as the phase's "
    "outcome, and an outcome is flattened onto one line and cut at 240 "
    "characters because it is the caption the route map draws under a leg. So "
    "every answer reached the phone as a single clipped line, and anything "
    "written before the last block of a turn was dropped entirely.\n\n"
    "If you can read this third paragraph, and the blank lines between the "
    "three survived, then the text is not being truncated and not being "
    "collapsed. If instead this ends in a single line with an ellipsis, the "
    "fix did not reach the device."
)


def inject_prose(events):
    outcomes = [e for e in events if e.get("kind") == "outcome" and e.get("phase")]
    if not outcomes:
        return events
    target = outcomes[0]
    seq = max(e["seq"] for e in events)
    for text in (_PROSE_LEAD, _PROSE_BODY):
        seq += 1
        events.append({
            "seq": seq,
            "kind": "claude",
            "text": text,
            "at": target["at"],
            "agent": target.get("agent"),
            "phase": target["phase"],
        })
    return events


inject_prose(HISTORY["events"])

# The roster's own time fields, so the rows show live relative stamps and the
# ELAPSED clock actually ticks.
for a in ROSTER["agents"]:
    if a.get("declaredAt"):
        a["declaredAt"] = BOOT - random.Random(a["name"]).uniform(300, 9000)
    if a.get("lastToolAt"):
        a["lastToolAt"] = BOOT - random.Random(a["name"] + "t").uniform(5, 400)

# The blocked agent. `blocked` alone flips presence; `blockedSince` is what
# makes InstrumentStrip's fourth cell a live ticking clock rather than a static
# one, so both are set.
for a in ROSTER["agents"]:
    if a["name"] == BLOCKED:
        a["blocked"] = True
        a["blockedSince"] = BOOT - 214.0
        v = a.get("vitals") or {}
        v["blockedFor"] = 214.0
        # A context reading, so the strip lays out four cells and draws its bar
        # instead of silently dropping the cell.
        v.setdefault("tokensPerSec", 41.7)
        v.setdefault("toolsPerMin", 6.4)
        v["contextUsed"] = 0.62
        a["vitals"] = v
        a["contextAvailable"] = True

# One agent pushed over the 85% line, because "hot" is a different colour and a
# still frame cannot tell you whether that branch was ever taken.
for a in ROSTER["agents"]:
    if a["name"] == "hotline-80":
        v = a.get("vitals") or {}
        v["contextUsed"] = 0.91
        v.setdefault("tokensPerSec", 88.2)
        v.setdefault("toolsPerMin", 12.1)
        a["vitals"] = v
        a["contextAvailable"] = True

# The question the blocked agent is waiting on. This is what puts real text in
# the row's subtitle and drives the answer flow rather than a generic bubble.
CONVERSATIONS = {
    "conversations": [
        {
            "conversation": "c-ci-1",
            "agent": BLOCKED,
            "opened": BOOT - 214.0,
            "asked": "The simulator run needs a server it can reach. Point it at the "
                     "stub on loopback, or fail the job and wait for the tailnet?",
            "answered": False,
            "closed": False,
            "waiting": True,
        }
    ]
}

# --------------------------------------------------------------------------
# The growing feed.

_TEMPLATES = [e for e in FEED["events"] if e.get("kind") == "tool"]
_next_seq = max((e["seq"] for e in HISTORY["events"]), default=1000) + 1
_released: list[dict] = []
_first_feed_at: float | None = None


def release_due():
    """Release one synthetic event per FEED_TICK since the first feed poll."""
    global _next_seq, _first_feed_at
    now = time.time()
    if _first_feed_at is None:
        _first_feed_at = now
        return
    want = int((now - _first_feed_at) / FEED_TICK)
    while len(_released) < want and len(_released) < 24:
        src = copy.deepcopy(_TEMPLATES[len(_released) % len(_TEMPLATES)])
        src["seq"] = _next_seq
        src["at"] = now
        _next_seq += 1
        _released.append(src)


# --------------------------------------------------------------------------


def roster_for(agent_name: str):
    """History always answers for whichever agent was asked for.

    The capture is `hotline-80`'s. Echoing the requested name keeps `Channel`
    from discarding a page it thinks belongs to someone else.
    """
    page = copy.deepcopy(HISTORY)
    page["agent"] = agent_name
    for e in page["events"]:
        e["agent"] = agent_name
    return page


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("stub %s - %s\n" % (self.address_string(), fmt % args))

    def reply(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if not n:
            return {}
        try:
            return json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            return {}

    def do_GET(self):
        if self.path.split("?")[0] == "/health":
            return self.reply(HEALTH)
        return self.reply({"error": "no such endpoint: " + self.path}, 404)

    def do_POST(self):
        path = self.path.split("?")[0]
        req = self.body()
        agent = req.get("agent") or BLOCKED

        if path == "/api/v1/agents":
            return self.reply(ROSTER)

        if path == "/api/v1/agents/roster-events":
            since = int(req.get("since") or 0)
            time.sleep(min(POLL_HOLD, float(req.get("wait") or POLL_HOLD)))
            return self.reply({"events": [], "cursor": since})

        if path == "/api/v1/agents/history":
            return self.reply(roster_for(agent))

        if path == "/api/v1/agents/feed":
            since = int(req.get("since") or 0)
            deadline = time.time() + min(POLL_HOLD, float(req.get("wait") or POLL_HOLD))
            while True:
                with LOCK:
                    release_due()
                    fresh = [e for e in _released if e["seq"] > since]
                if fresh or time.time() >= deadline:
                    break
                time.sleep(0.2)
            for e in fresh:
                e["agent"] = agent
            return self.reply({
                "agent": agent,
                "events": fresh,
                "cursor": fresh[-1]["seq"] if fresh else since,
                "closed": False,
                "historyGeneration": 0,
            })

        if path == "/api/v1/conversations":
            return self.reply(CONVERSATIONS)

        if path == "/api/v1/say":
            return self.reply({"conversation": "c-ci-said"})

        if path == "/api/v1/reply":
            return self.reply({"delivered": True})

        if path == "/api/v1/agents/stop":
            return self.reply({"agent": agent, "interrupted": True})

        if path == "/api/v1/agents/kill":
            return self.reply({"agent": agent, "outcome": "killed"})

        if path == "/api/v1/agents/retask":
            # camelCase, because Wire.swift's RetaskResult has no CodingKeys and
            # therefore reads the literal key `clientToken`. The real daemon
            # sends `client_token`, which silently decodes to nil there -- a
            # genuine mismatch, recorded in the notes rather than papered over.
            return self.reply({
                "agent": agent,
                "delivered": True,
                "queued": False,
                "clientToken": req.get("client_token"),
            })

        if path == "/api/v1/agents/resume":
            return self.reply({"agent": agent, "session": "s-ci", "from_handoff": False})

        if path == "/api/v1/agents/new":
            return self.reply({"agent": "ci-new", "session": "s-ci-new"})

        if path == "/api/v1/agents/compact":
            return self.reply({
                "agent": agent, "interrupted": True, "compacted": True, "resumed": True,
                "preTokens": 48000, "postTokens": 4100, "durationMs": 71000,
                "detail": "Compacted - 48.0k -> 4.1k in 71s",
            })

        if path == "/api/v1/agents/retire":
            return self.reply({"agent": agent, "retired": bool(req.get("retired"))})

        if path == "/api/v1/agents/purge":
            out = dict(PURGE)
            out["agent"] = agent
            out["dry_run"] = bool(req.get("dry_run"))
            return self.reply(out)

        return self.reply({"error": "no such endpoint: " + path}, 404)


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print(f"stub daemon on 127.0.0.1:{PORT}", flush=True)
    print(f"  roster: {len(ROSTER['agents'])} agents, blocked: {BLOCKED}", flush=True)
    print(f"  history: {len(HISTORY['events'])} events, "
          f"{len({e.get('phase') for e in HISTORY['events'] if e.get('phase')})} phases",
          flush=True)
    srv.serve_forever()
