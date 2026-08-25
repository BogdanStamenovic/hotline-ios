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


class Waker:
    """Broadcast wake-up with no per-waiter bookkeeping.

    Set the event and clear it in the same tick: every waiter currently parked
    gets released, and nothing arriving later finds a stale set flag. The waiters
    re-read from a cursor rather than from this object, so a missed wake costs
    latency and never an event -- which is why one shared flag is enough and a
    queue per waiter is not needed.

    Lifted out of `EventLog` unchanged because the agent-scoped feed needs the
    same primitive over rows that live in SQLite rather than in a deque. Two
    copies of a concurrency pattern is how you end up with one of them wrong.
    """

    __slots__ = ("_arrived",)

    def __init__(self) -> None:
        self._arrived = asyncio.Event()

    def wake(self) -> None:
        self._arrived.set()
        self._arrived.clear()

    async def sleep(self, timeout: float) -> bool:
        """Park until someone calls `wake()`. True if woken, False on timeout."""
        if timeout <= 0:
            return False
        try:
            await asyncio.wait_for(self._arrived.wait(), timeout)
        except TimeoutError:
            return False
        return True


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
    _latest: int = 0
    dropped: int = 0
    closed: bool = False
    _arrived: Waker = field(default_factory=Waker)

    def append(self, kind: str, text: str, tool: str | None = None, at: float = 0.0) -> Entry:
        # `max` rather than a bare counter so that self-numbering stays
        # monotonic in a log that has also adopted store-assigned seqs. Mixing
        # the two is not how the daemon drives this, but it is exactly what a
        # test reaching in from the side does, and a silently-lower seq is
        # invisible to every waiter parked on a higher cursor.
        seq = max(self._next_seq, self._latest + 1)
        self._next_seq = seq + 1
        return self.adopt(Entry(seq=seq, kind=kind, text=text, tool=tool, at=at))

    def adopt(self, entry: Entry) -> Entry:
        """Index an entry whose `seq` was assigned somewhere else.

        The store owns one global sequence now, so a conversation's numbers are
        no longer contiguous -- 41, 44, 45 is a normal conversation once another
        agent has been talking in between. Nothing here cares: `since` is a `>`
        and `gap` compares against the oldest entry actually held, both of which
        are true of a sparse sequence.

        `_next_seq` is left alone deliberately. It belongs to the self-numbering
        path (`append`), which the store-backed daemon no longer uses but the
        log's own tests still do.
        """
        if len(self.entries) == self.entries.maxlen:
            self.dropped += 1
        self.entries.append(entry)
        self._latest = max(self._latest, entry.seq)
        self._arrived.wake()
        return entry

    def since(self, cursor: int) -> list[Entry]:
        return [entry for entry in self.entries if entry.seq > cursor]

    @property
    def latest(self) -> int:
        return self._latest

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
        if not await self._arrived.sleep(timeout):
            return []
        return self.since(cursor)

    def close(self) -> None:
        self.closed = True
        self._arrived.wake()
