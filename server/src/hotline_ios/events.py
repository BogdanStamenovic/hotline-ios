"""The live feed a phone or a browser reads during a call.

`SPEC.md` §5 wants the in-call screen to show a live transcript and which tool
Claude is running right now, and §5 also requires the whole thing to survive
"the network moving between wifi and cellular". Those two requirements together
decide the design, and they decide it against the obvious answer.

**Why a cursor and long-polling rather than SSE or a WebSocket.**

A phone moving from wifi to cellular changes its source address, and every
long-lived connection dies. So a streaming transport does not remove the need
for reconnect logic -- it adds it, and then needs a replay mechanism on top so
the reconnect does not lose the events that arrived during the gap. Once you
have built the cursor you need for that, the streaming socket is carrying
almost nothing the cursor could not.

Long-polling with a sequence number is that cursor and nothing else:

    GET /api/v1/calls/<id>/events?since=41&wait=25

returns everything after 41, blocking until something arrives or the wait
expires. A reconnect is the same request with the same cursor, so a handover
costs one round trip and loses nothing. It also works unmodified through
hotline's existing HTTP server, which closes every connection by design and
speaks neither chunked encoding nor the WebSocket upgrade -- so this choice
means not forking that server, which is worth something on its own.

The cost is one idle request in flight per viewer. Over a tailnet, for one
person, that is not a cost.
"""

from __future__ import annotations

import asyncio
from collections import deque
from dataclasses import dataclass, field
from typing import Any

MAX_EVENTS = 500
"""Per call. A long call narrating every tool use might produce a few hundred;
past that the oldest are dropped, and `dropped` says so rather than pretending
the log is complete."""


@dataclass
class Entry:
    seq: int
    kind: str
    text: str
    tool: str | None
    at: float

    def as_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {"seq": self.seq, "kind": self.kind, "text": self.text, "at": self.at}
        if self.tool:
            out["tool"] = self.tool
        return out


@dataclass
class EventLog:
    """An append-only log with a cursor, and a way to wait for the next entry."""

    entries: deque[Entry] = field(default_factory=lambda: deque(maxlen=MAX_EVENTS))
    _next_seq: int = 1
    dropped: int = 0
    closed: bool = False
    _arrived: asyncio.Event = field(default_factory=asyncio.Event)

    def append(self, kind: str, text: str, tool: str | None = None, at: float = 0.0) -> Entry:
        if len(self.entries) == self.entries.maxlen:
            self.dropped += 1
        entry = Entry(seq=self._next_seq, kind=kind, text=text, tool=tool, at=at)
        self._next_seq += 1
        self.entries.append(entry)
        # Wake every waiter, then immediately re-arm. An Event that is set and
        # cleared in the same tick is the standard way to do a broadcast without
        # keeping a per-waiter queue; the waiters re-read from the cursor rather
        # than from the Event, so a missed wake costs latency and never an event.
        self._arrived.set()
        self._arrived.clear()
        return entry

    def since(self, cursor: int) -> list[Entry]:
        return [entry for entry in self.entries if entry.seq > cursor]

    @property
    def latest(self) -> int:
        return self._next_seq - 1

    @property
    def oldest(self) -> int:
        return self.entries[0].seq if self.entries else self._next_seq

    def gap(self, cursor: int) -> bool:
        """True when the caller's cursor is older than anything still held, so
        it has provably missed events. Saying so beats silently resuming from a
        later point and letting the transcript look complete when it is not."""
        return bool(self.entries) and cursor < self.oldest - 1

    async def wait(self, cursor: int, timeout: float) -> list[Entry]:
        """Everything after `cursor`, blocking up to `timeout` for the first."""
        found = self.since(cursor)
        if found or self.closed or timeout <= 0:
            return found
        try:
            await asyncio.wait_for(self._arrived.wait(), timeout)
        except TimeoutError:
            return []
        return self.since(cursor)

    def close(self) -> None:
        self.closed = True
        self._arrived.set()
        self._arrived.clear()
