"""Durable state for the daemon: agents, conversations, events, phases.

Everything the daemon knew used to live in a dict and die with the process. That
was survivable while a conversation was a thing you answered within a minute; it
stops being survivable the moment the phone wants *history* -- a channel per
agent, scrollable backwards, that outlives a restart of a daemon nobody watches.

**SQLite, stdlib, WAL.** No new dependency, ordered and indexed queries for free,
and single-writer/many-reader is exactly the shape of this process. It lives
under the same `XDG_STATE_HOME` convention hotline's `Registry` already uses, so
whatever backs that up picks this up too without a special case.

**One global `seq`.** The load-bearing decision. `EventLog` numbered events per
conversation; this numbers them once across every agent and every conversation.
History and the live feed then become the same `WHERE seq > ?` against one
table, so "no gap, no duplicate" is a property of `>` on a primary key rather
than something the client has to reconcile. It also means a purge can leave
holes in the sequence and nothing breaks -- holes are fine, reordering is not.

**Roster ticks share that sequence** rather than getting a table of their own.
They are stored as events with `kind = "roster"` and no conversation, and every
transcript-facing query filters that kind out. The alternative was a second
sequence the client would have to hold a second cursor for, to solve a problem
the first cursor already solves.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

log = logging.getLogger("hotline-iosd.store")

ROSTER_KIND = "roster"
"""Reserved `events.kind`. Carries roster invalidation ticks on the same global
sequence as everything else; excluded from every transcript-facing query."""

UNATTRIBUTED = "(unattributed)"
"""Where a conversation goes when nothing named an agent.

`hotline-call --agent` defaults to None, so this is not an edge case, it is the
common case for a plain ring. The row still has to go somewhere -- dropping it
would lose the question he is about to answer -- and a reserved name that cannot
collide with a registry name (`hotline-80`, `data-88`) is better than a NULL
that every query then has to special-case. It is filtered out of the roster: it
is a bucket, not an agent."""

MAX_ROSTER_TICKS = 500
"""How many roster invalidation ticks are kept, approximately.

Approximately because the trim runs every `ROSTER_TRIM_EVERY` appends, so the
real count sits between this and this plus that. Nothing depends on the exact
figure: a tick is an invalidation and holding a few too many costs bytes."""

ROSTER_TRIM_EVERY = 64
"""Trim once every this many ticks rather than on each one -- the trim is a
scan-and-delete and doing it per append would pay for a bound that is only ever
approached slowly."""

MAX_PAGE = 200
"""Ceiling on `history(limit=)`. §6 of the plan; also stops one request from
pulling a hundred thousand rows into a phone."""

SCHEMA = """
CREATE TABLE IF NOT EXISTS agents (
  name TEXT PRIMARY KEY,
  session_id TEXT,
  task TEXT, cwd TEXT,
  declared_at REAL, completed_at REAL,
  last_tool_at REAL,
  retired_at REAL,
  history_generation INTEGER NOT NULL DEFAULT 0,
  transcript_offset INTEGER NOT NULL DEFAULT 0,
  updated_at REAL
);

CREATE TABLE IF NOT EXISTS conversations (
  id TEXT PRIMARY KEY,
  agent_name TEXT NOT NULL REFERENCES agents(name),
  kind TEXT NOT NULL,
  opened_at REAL NOT NULL, closed_at REAL,
  waiting_since REAL,
  answered INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  conversation_id TEXT REFERENCES conversations(id),
  agent_name TEXT NOT NULL,
  kind TEXT NOT NULL,
  phase_id TEXT,
  tool TEXT, text TEXT NOT NULL,
  via_subagent INTEGER NOT NULL DEFAULT 0,
  at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS events_agent_seq ON events(agent_name, seq);
CREATE INDEX IF NOT EXISTS events_conversation_seq ON events(conversation_id, seq);
CREATE INDEX IF NOT EXISTS events_kind_seq ON events(kind, seq);
CREATE INDEX IF NOT EXISTS events_at ON events(kind, at);

CREATE TABLE IF NOT EXISTS phases (
  id TEXT PRIMARY KEY, agent_name TEXT NOT NULL, conversation_id TEXT,
  title TEXT NOT NULL, outcome TEXT,
  started_at REAL NOT NULL, ended_at REAL
);
CREATE INDEX IF NOT EXISTS phases_agent ON phases(agent_name, started_at);
CREATE INDEX IF NOT EXISTS phases_open ON phases(agent_name, ended_at);
"""

AGENT_MIGRATIONS = {
    # Per-subagent byte offsets, as JSON. Not a second INTEGER because there is
    # one sidechain file per subagent and they are appended to concurrently with
    # the main transcript; see `transcript.sidechain_paths`.
    "transcript_sidechains": "ALTER TABLE agents ADD COLUMN transcript_sidechains TEXT",
    # `context_window.used_percentage` from the statusLine payload, 0..1. NULL
    # until a first sample arrives -- the CLI reports null before a session's
    # first turn, and storing that as zero would draw a full context gauge on a
    # session that has used none of it.
    "context_used": "ALTER TABLE agents ADD COLUMN context_used REAL",
    "context_used_at": "ALTER TABLE agents ADD COLUMN context_used_at REAL",
    # When this daemon last received a statusLine report for this agent, of any
    # kind -- including the ones carrying `null`. It is the whole of
    # `contextAvailable`: a session that has reported once has the wrapper
    # installed, so a missing `context_used` means "no first turn yet", and a
    # session that has never reported has no wrapper, so it means "never". Those
    # render identically and mean opposite things (§5.6), which is why it is
    # observed rather than inferred from a settings file the session may have
    # been started before.
    "statusline_at": "ALTER TABLE agents ADD COLUMN statusline_at REAL",
}
"""Columns added to `agents` after the first schema shipped.

`CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists, and
the database serving his phone already existed, so new columns need a real
`ALTER TABLE` guarded by what is already there."""

EVENT_MIGRATIONS = {
    # How long the tool call this row describes actually took. It is in the
    # `PostToolUse` hook payload and was thrown away; the app's tool-row duration
    # bar renders nothing at all rather than a guessed width without it, which
    # is correct and is also why it was worth wiring up.
    "duration_ms": "ALTER TABLE events ADD COLUMN duration_ms REAL",
    # The phone's own id for something it sent. Echoed back on the response and
    # carried on the resulting row, so reconciling a local echo against the feed
    # is an equality test rather than a FIFO assumption -- and so a retry after a
    # timeout is detectable as a duplicate instead of being delivered twice.
    "client_token": "ALTER TABLE events ADD COLUMN client_token TEXT",
    # The CLI's own id for the tool call this row describes. Kept so the
    # `PostToolUse` nudge -- which arrives after the row has been written from
    # the transcript -- can find the row it belongs to and fill in its duration.
    "tool_use_id": "ALTER TABLE events ADD COLUMN tool_use_id TEXT",
}

MIGRATIONS = {"agents": AGENT_MIGRATIONS, "events": EVENT_MIGRATIONS}


@dataclass(frozen=True)
class StoredEvent:
    seq: int
    conversation_id: str | None
    agent_name: str
    kind: str
    phase_id: str | None
    tool: str | None
    text: str
    via_subagent: bool
    at: float
    duration_ms: float | None = None
    client_token: str | None = None
    tool_use_id: str | None = None

    def as_json(self) -> dict[str, Any]:
        """The wire shape `/api/v1/events` has always returned.

        Byte-for-byte the same keys `events.Entry.as_json` produces, because the
        app installed on his phone decodes exactly these and a reinstall costs a
        7-day provisioning profile.
        """
        out: dict[str, Any] = {"seq": self.seq, "kind": self.kind, "text": self.text, "at": self.at}
        if self.tool:
            out["tool"] = self.tool
        # Both omitted rather than sent as null when there is nothing to say.
        # The app's duration bar renders only when a real number arrives, and a
        # present-but-null field is a second way to say absent.
        if self.duration_ms is not None:
            out["duration_ms"] = self.duration_ms
        if self.client_token:
            out["client_token"] = self.client_token
        return out

    def as_agent_json(self) -> dict[str, Any]:
        """The same event on an agent-scoped feed, which interleaves sources.

        A ring's Q&A, a delegated `say` and (once the hook lands) tool events all
        share one channel, so a row has to be able to say which conversation it
        came from and whether a subagent produced it.
        """
        out = self.as_json()
        out["agent"] = self.agent_name
        if self.conversation_id:
            out["conversation"] = self.conversation_id
        if self.via_subagent:
            out["viaSubagent"] = True
        if self.phase_id:
            out["phase"] = self.phase_id
        return out


def default_path() -> Path:
    """Beside hotline's `agents.json`, by the same rules.

    Asks hotline for the directory when hotline is importable so the two cannot
    drift, and falls back to reimplementing the three lines when it is not --
    this package is tested without hotline on the path.
    """
    override = os.environ.get("HOTLINE_IOS_DB")
    if override:
        return Path(override)
    try:
        from hotline.config import state_dir

        return Path(state_dir()) / "hotline-ios.db"
    except Exception:  # noqa: BLE001 - hotline is a PYTHONPATH dependency, not an installed one
        env = os.environ.get("HOTLINE_STATE")
        if env:
            return Path(env) / "hotline-ios.db"
        xdg = os.environ.get("XDG_STATE_HOME") or (Path.home() / ".local" / "state")
        return Path(xdg) / "hotline" / "hotline-ios.db"


class Store:
    """The durable half of the daemon. Synchronous on purpose.

    Every query here is a primary-key or covered-index lookup against a database
    measured in megabytes, on the same box. Wrapping that in `to_thread` would
    add a context switch per event to save microseconds of loop time, and would
    hand a single-writer database to a thread pool for no reason.

    The lock is not for that. It is because the HTTP handlers run on the event
    loop while tests drive the store from the main thread and `sqlite3` objects
    are not free-threaded; `check_same_thread=False` plus one lock is the
    smallest correct answer.
    """

    def __init__(self, path: str | Path | None = None) -> None:
        self.path = Path(path) if path is not None else default_path()
        self._lock = threading.RLock()
        self._roster_appends = 0
        if str(self.path) != ":memory:":
            self.path.parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(self.path), check_same_thread=False, timeout=5.0)
        self.db.row_factory = sqlite3.Row
        with self._lock:
            # WAL is meaningless in memory and PRAGMA does not raise for it, so
            # this is a no-op rather than a special case.
            self.db.execute("PRAGMA journal_mode=WAL")
            self.db.execute("PRAGMA synchronous=NORMAL")
            # ON by choice: an event attributed to an agent row that does not
            # exist is a bug in this file, and it should surface here rather
            # than as an empty feed three days later.
            self.db.execute("PRAGMA foreign_keys=ON")
            self.db.executescript(SCHEMA)
            self._migrate()
            self.db.commit()

    def _migrate(self) -> None:
        """Add columns the first schema did not have. Caller holds the lock."""
        for table, columns in MIGRATIONS.items():
            have = {row["name"] for row in self.db.execute(f"PRAGMA table_info({table})")}
            for column, statement in columns.items():
                if column not in have:
                    self.db.execute(statement)

    def close(self) -> None:
        with self._lock:
            self.db.close()

    # ---- agents ----------------------------------------------------------

    def ensure_agent(self, name: str, **fields: Any) -> None:
        """Make sure a row exists for `name`, then update whatever was supplied.

        Upsert rather than insert-or-ignore: the roster learns an agent's
        session, task and cwd at different moments from different sources, and
        the first one to arrive must not pin the rest to NULL forever.
        """
        known = {"session_id", "task", "cwd", "declared_at", "completed_at",
                 "last_tool_at", "transcript_offset"}
        unknown = set(fields) - known
        if unknown:
            raise ValueError(f"ensure_agent got unknown fields: {sorted(unknown)}")
        now = time.time()
        with self._lock:
            self.db.execute(
                "INSERT INTO agents (name, declared_at, updated_at) VALUES (?, ?, ?) "
                "ON CONFLICT(name) DO NOTHING",
                (name, now, now),
            )
            supplied = {k: v for k, v in fields.items() if v is not None}
            if supplied:
                assignments = ", ".join(f"{k} = ?" for k in supplied)
                self.db.execute(
                    f"UPDATE agents SET {assignments}, updated_at = ? WHERE name = ?",
                    (*supplied.values(), now, name),
                )
            self.db.commit()

    def agent(self, name: str) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute("SELECT * FROM agents WHERE name = ?", (name,)).fetchone()
        return dict(row) if row is not None else None

    def agents(self) -> list[dict[str, Any]]:
        with self._lock:
            rows = self.db.execute("SELECT * FROM agents ORDER BY name").fetchall()
        return [dict(row) for row in rows]

    def set_retired(self, name: str, retired: bool) -> float | None:
        """Flip visibility. Reversible, destroys nothing, orthogonal to liveness.

        Returns the new `retired_at`, so a caller can report what actually
        happened rather than echoing what it asked for.
        """
        at = time.time() if retired else None
        with self._lock:
            self.ensure_agent(name)
            self.db.execute(
                "UPDATE agents SET retired_at = ?, updated_at = ? WHERE name = ?",
                (at, time.time(), name),
            )
            self.db.commit()
        return at

    def set_last_tool_at(self, name: str, at: float) -> None:
        with self._lock:
            self.ensure_agent(name)
            self.db.execute(
                "UPDATE agents SET last_tool_at = ?, updated_at = ? WHERE name = ?",
                (at, time.time(), name),
            )
            self.db.commit()

    def history_generation(self, name: str) -> int:
        row = self.agent(name)
        return int(row["history_generation"]) if row else 0

    # ---- where the transcript reader has got to -------------------------

    def read_position(self, name: str) -> tuple[int, dict[str, int]]:
        """`(main transcript offset, per-sidechain-file offsets)`.

        Both halves are durable on purpose. Keeping the sidechain offsets in
        memory would make a daemon restart replay every subagent's whole file
        into the map as if it had just happened.
        """
        row = self.agent(name)
        if row is None:
            return 0, {}
        offset = int(row["transcript_offset"] or 0)
        try:
            raw = json.loads(row["transcript_sidechains"] or "{}")
            sidechains = {str(k): int(v) for k, v in raw.items()} if isinstance(raw, dict) else {}
        except (ValueError, TypeError):
            # A corrupt blob costs a replay of the subagent files, not a crash.
            log.warning("unreadable sidechain offsets for %s; starting them over", name)
            sidechains = {}
        return offset, sidechains

    def set_read_position(self, name: str, offset: int, sidechains: dict[str, int]) -> None:
        with self._lock:
            self.ensure_agent(name)
            self.db.execute(
                "UPDATE agents SET transcript_offset = ?, transcript_sidechains = ?, "
                "updated_at = ? WHERE name = ?",
                (int(offset), json.dumps(sidechains), time.time(), name),
            )
            self.db.commit()

    def set_context_used(self, name: str, fraction: float, *, at: float | None = None) -> None:
        """Record `context_window.used_percentage / 100` for a session.

        Only ever called with a real sample. The CLI reports `null` before a
        session's first turn and the caller drops that rather than storing zero:
        "unknown" and "none used" are different states and the app renders them
        differently.
        """
        with self._lock:
            self.ensure_agent(name)
            self.db.execute(
                "UPDATE agents SET context_used = ?, context_used_at = ?, updated_at = ? "
                "WHERE name = ?",
                (float(fraction), time.time() if at is None else at, time.time(), name),
            )
            self.db.commit()

    # ---- phases ----------------------------------------------------------

    def open_phase(
        self,
        phase_id: str,
        agent_name: str,
        title: str,
        *,
        conversation_id: str | None = None,
        started_at: float | None = None,
    ) -> None:
        """Start a phase. The title is frozen here and never rewritten.

        §2: a title that shifts under a finger mid-scroll is worse than a duller
        one that holds still. What arrives later is the `outcome`, a separate
        field, so the row reads ask-then-answer rather than mutating in place.
        """
        with self._lock:
            self.ensure_agent(agent_name)
            self.db.execute(
                "INSERT OR REPLACE INTO phases "
                "(id, agent_name, conversation_id, title, outcome, started_at, ended_at) "
                "VALUES (?, ?, ?, ?, NULL, ?, NULL)",
                (phase_id, agent_name, conversation_id, title,
                 time.time() if started_at is None else started_at),
            )
            self.db.commit()

    def close_phase(
        self, phase_id: str, *, outcome: str | None = None, ended_at: float | None = None
    ) -> bool:
        """Idempotent: closing a phase twice is not an error, and the second
        close does not overwrite the first outcome with a null."""
        with self._lock:
            cur = self.db.execute(
                "UPDATE phases SET ended_at = ?, outcome = COALESCE(?, outcome) "
                "WHERE id = ? AND ended_at IS NULL",
                (time.time() if ended_at is None else ended_at, outcome, phase_id),
            )
            self.db.commit()
        return cur.rowcount > 0

    def open_phase_of(self, agent_name: str) -> dict[str, Any] | None:
        """The agent's one unfinished phase, newest if somehow there are several."""
        with self._lock:
            row = self.db.execute(
                "SELECT * FROM phases WHERE agent_name = ? AND ended_at IS NULL "
                "ORDER BY started_at DESC LIMIT 1",
                (agent_name,),
            ).fetchone()
        return dict(row) if row is not None else None

    def phase_at(self, agent_name: str, at: float) -> dict[str, Any] | None:
        """The phase that was running when `at` happened, open or closed.

        Needed because a subagent's tool calls do not arrive while the parent's
        phase is still open. A background subagent outlives the turn that
        spawned it entirely, and even a foreground one has its file written
        after the parent's Stop, so by the time those records are read the phase
        they belong to has already closed. Attributing them to the phase that
        was current at their own timestamp is the honest answer; dropping them
        on the floor as unphased is what happens otherwise.

        Deliberately not bounded by `ended_at`: work a phase started is that
        phase's work even when it finishes after it.
        """
        with self._lock:
            row = self.db.execute(
                "SELECT * FROM phases WHERE agent_name = ? AND started_at <= ? "
                "ORDER BY started_at DESC LIMIT 1",
                (agent_name, at),
            ).fetchone()
        return dict(row) if row is not None else None

    def phase(self, phase_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute("SELECT * FROM phases WHERE id = ?", (phase_id,)).fetchone()
        return dict(row) if row is not None else None

    def phases(self, agent_name: str, *, limit: int = MAX_PAGE) -> list[dict[str, Any]]:
        """Newest first, which is the order a phone scrolls them in."""
        with self._lock:
            rows = self.db.execute(
                "SELECT * FROM phases WHERE agent_name = ? ORDER BY started_at DESC LIMIT ?",
                (agent_name, max(1, min(int(limit), MAX_PAGE))),
            ).fetchall()
        return [dict(row) for row in rows]

    # ---- conversations ---------------------------------------------------

    def open_conversation(
        self,
        conversation_id: str,
        agent_name: str,
        kind: str,
        *,
        opened_at: float | None = None,
        waiting_since: float | None = None,
    ) -> None:
        opened_at = time.time() if opened_at is None else opened_at
        with self._lock:
            self.ensure_agent(agent_name)
            self.db.execute(
                "INSERT OR REPLACE INTO conversations "
                "(id, agent_name, kind, opened_at, closed_at, waiting_since, answered) "
                "VALUES (?, ?, ?, ?, NULL, ?, 0)",
                (conversation_id, agent_name, kind, opened_at, waiting_since),
            )
            self.db.commit()

    def close_conversation(self, conversation_id: str, *, at: float | None = None) -> bool:
        """Mark a conversation ended. Idempotent -- a second close is not an error."""
        with self._lock:
            cur = self.db.execute(
                "UPDATE conversations SET closed_at = ?, waiting_since = NULL "
                "WHERE id = ? AND closed_at IS NULL",
                (time.time() if at is None else at, conversation_id),
            )
            self.db.commit()
        return cur.rowcount > 0

    def mark_answered(self, conversation_id: str) -> None:
        """He replied. The agent is no longer blocked on him, whatever else is true."""
        with self._lock:
            self.db.execute(
                "UPDATE conversations SET answered = 1, waiting_since = NULL WHERE id = ?",
                (conversation_id,),
            )
            self.db.commit()

    def conversation(self, conversation_id: str) -> dict[str, Any] | None:
        with self._lock:
            row = self.db.execute(
                "SELECT * FROM conversations WHERE id = ?", (conversation_id,)
            ).fetchone()
        return dict(row) if row is not None else None

    def conversations(
        self, *, agent: str | None = None, since: float | None = None, limit: int = MAX_PAGE
    ) -> list[dict[str, Any]]:
        """Newest first, which is the order every caller wants them in."""
        clauses: list[str] = []
        params: list[Any] = []
        if agent is not None:
            clauses.append("agent_name = ?")
            params.append(agent)
        if since is not None:
            clauses.append("opened_at >= ?")
            params.append(since)
        where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
        params.append(limit)
        with self._lock:
            rows = self.db.execute(
                f"SELECT * FROM conversations {where} ORDER BY opened_at DESC LIMIT ?", params
            ).fetchall()
        return [dict(row) for row in rows]

    def blocked_since(self) -> dict[str, float]:
        """agent -> when it first started waiting on him, across open conversations.

        The earliest, not the latest: an agent blocked on two questions has been
        blocked since the first one, and showing the second would under-report
        exactly the number the pin exists to make loud.
        """
        with self._lock:
            rows = self.db.execute(
                "SELECT agent_name, MIN(waiting_since) AS since FROM conversations "
                "WHERE closed_at IS NULL AND answered = 0 AND waiting_since IS NOT NULL "
                "GROUP BY agent_name"
            ).fetchall()
        return {row["agent_name"]: float(row["since"]) for row in rows}

    # ---- events ----------------------------------------------------------

    def append_event(
        self,
        agent_name: str,
        kind: str,
        text: str,
        *,
        conversation_id: str | None = None,
        tool: str | None = None,
        phase_id: str | None = None,
        via_subagent: bool = False,
        at: float | None = None,
        duration_ms: float | None = None,
        client_token: str | None = None,
        tool_use_id: str | None = None,
    ) -> StoredEvent:
        at = time.time() if at is None else at
        with self._lock:
            self.ensure_agent(agent_name)
            cur = self.db.execute(
                "INSERT INTO events "
                "(conversation_id, agent_name, kind, phase_id, tool, text, via_subagent, at, "
                " duration_ms, client_token, tool_use_id) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (conversation_id, agent_name, kind, phase_id, tool, text, int(via_subagent), at,
                 duration_ms, client_token, tool_use_id),
            )
            self.db.commit()
            seq = int(cur.lastrowid or 0)
        return StoredEvent(
            seq=seq,
            conversation_id=conversation_id,
            agent_name=agent_name,
            kind=kind,
            phase_id=phase_id,
            tool=tool,
            text=text,
            via_subagent=via_subagent,
            at=at,
            duration_ms=duration_ms,
            client_token=client_token,
            tool_use_id=tool_use_id,
        )

    def set_duration(self, tool_use_id: str, duration_ms: float) -> bool:
        """Fill in how long one tool call took. Returns whether a row was found.

        The number comes from the `PostToolUse` hook payload, which is the only
        place it exists -- the transcript's `durationMs` is a whole turn's, not
        a tool's, and there is nothing per-call in the file at all. Reported
        rather than assumed: a miss means the row was never written (the nudge
        for it was dropped, or the read is behind), and the app renders no
        duration bar instead of a guessed one.
        """
        if not tool_use_id:
            return False
        with self._lock:
            cur = self.db.execute(
                "UPDATE events SET duration_ms = ? WHERE tool_use_id = ? AND duration_ms IS NULL",
                (float(duration_ms), tool_use_id),
            )
            self.db.commit()
        return bool(cur.rowcount)

    def set_statusline_seen(self, name: str, at: float | None = None) -> None:
        """Note that the statusline wrapper reported for this agent at all.

        Called for every statusLine nudge including the ones carrying no usage
        figure, because the question this answers is "is the wrapper installed",
        not "how full is the context".
        """
        with self._lock:
            self.ensure_agent(name)
            self.db.execute(
                "UPDATE agents SET statusline_at = ?, updated_at = ? WHERE name = ?",
                (time.time() if at is None else at, time.time(), name),
            )
            self.db.commit()

    def tools_since(self, since: float) -> dict[str, int]:
        """agent -> tool calls after `since`. One query for the whole roster.

        Per-agent counting would be one query per row on an endpoint that is
        also the body of a long-poll; this is a single grouped scan over an
        index on `(kind, at)`.
        """
        with self._lock:
            rows = self.db.execute(
                "SELECT agent_name, COUNT(*) AS n FROM events "
                "WHERE kind = 'tool' AND at > ? GROUP BY agent_name",
                (float(since),),
            ).fetchall()
        return {row["agent_name"]: int(row["n"]) for row in rows}

    def _rows(self, sql: str, params: Any) -> list[StoredEvent]:
        with self._lock:
            rows = self.db.execute(sql, params).fetchall()
        return [
            StoredEvent(
                seq=int(row["seq"]),
                conversation_id=row["conversation_id"],
                agent_name=row["agent_name"],
                kind=row["kind"],
                phase_id=row["phase_id"],
                tool=row["tool"],
                text=row["text"],
                via_subagent=bool(row["via_subagent"]),
                at=float(row["at"]),
                duration_ms=(
                    float(row["duration_ms"]) if row["duration_ms"] is not None else None
                ),
                client_token=row["client_token"],
                tool_use_id=row["tool_use_id"],
            )
            for row in rows
        ]

    def since(self, agent: str, cursor: int, *, limit: int = 500) -> list[StoredEvent]:
        """Everything an agent has produced after `cursor`, oldest first."""
        return self._rows(
            "SELECT * FROM events WHERE agent_name = ? AND seq > ? AND kind != ? "
            "ORDER BY seq LIMIT ?",
            (agent, cursor, ROSTER_KIND, limit),
        )

    def conversation_events(
        self, conversation_id: str, cursor: int = 0, *, limit: int = 500
    ) -> list[StoredEvent]:
        return self._rows(
            "SELECT * FROM events WHERE conversation_id = ? AND seq > ? AND kind != ? "
            "ORDER BY seq LIMIT ?",
            (conversation_id, cursor, ROSTER_KIND, limit),
        )

    def conversation_tail(self, conversation_id: str, *, limit: int = 500) -> list[StoredEvent]:
        """The newest `limit` events of a conversation, returned oldest first.

        What rehydrating an in-memory index after a restart needs: the recent
        end of a long conversation, in reading order.
        """
        newest = self._rows(
            "SELECT * FROM events WHERE conversation_id = ? AND kind != ? "
            "ORDER BY seq DESC LIMIT ?",
            (conversation_id, ROSTER_KIND, limit),
        )
        return list(reversed(newest))

    def history(
        self, agent: str, *, before: int | None = None, limit: int = 100
    ) -> tuple[list[StoredEvent], bool]:
        """A page of an agent's past, oldest first, walking backwards.

        Returns `(events, has_more)`. `before` is exclusive, so paging is
        `before = oldest_seq` of the page you just got and there is no
        off-by-one to get wrong at either end.
        """
        limit = max(1, min(int(limit), MAX_PAGE))
        # limit+1 rather than a second COUNT query: one scan answers both "the
        # page" and "is there anything behind it".
        if before is None:
            rows = self._rows(
                "SELECT * FROM events WHERE agent_name = ? AND kind != ? "
                "ORDER BY seq DESC LIMIT ?",
                (agent, ROSTER_KIND, limit + 1),
            )
        else:
            rows = self._rows(
                "SELECT * FROM events WHERE agent_name = ? AND seq < ? AND kind != ? "
                "ORDER BY seq DESC LIMIT ?",
                (agent, before, ROSTER_KIND, limit + 1),
            )
        has_more = len(rows) > limit
        page = rows[:limit]
        return list(reversed(page)), has_more

    def latest_seq(self) -> int:
        with self._lock:
            row = self.db.execute("SELECT MAX(seq) AS seq FROM events").fetchone()
        return int(row["seq"] or 0)

    # ---- roster ticks ----------------------------------------------------

    def append_roster_event(self, agent_name: str, text: str, *, at: float | None = None) -> int:
        seq = self.append_event(agent_name, ROSTER_KIND, text, at=at).seq
        self._roster_appends += 1
        if self._roster_appends % ROSTER_TRIM_EVERY == 0:
            self.trim_roster_events()
        return seq

    def trim_roster_events(self, *, keep: int = MAX_ROSTER_TICKS) -> int:
        """Drop all but the newest `keep` roster ticks.

        This is NOT the automatic retention §3 rules out. That decision is about
        his history -- the events, phases and conversations a purge exists to
        delete deliberately -- and none of it is touched here. Roster ticks are
        machine noise: a busy box with the app listening writes one every few
        seconds, forever, and they carry nothing that is not recomputable from
        the roster itself.

        A client whose cursor falls behind the trimmed window over-invalidates
        rather than under-invalidating: it still sees every remaining tick, so
        the worst case is one refetch too many, which is the safe direction.
        """
        with self._lock:
            cutoff = self.db.execute(
                "SELECT MIN(seq) AS seq FROM "
                "(SELECT seq FROM events WHERE kind = ? ORDER BY seq DESC LIMIT ?)",
                (ROSTER_KIND, keep),
            ).fetchone()["seq"]
            if cutoff is None:
                return 0
            cur = self.db.execute(
                "DELETE FROM events WHERE kind = ? AND seq < ?", (ROSTER_KIND, cutoff)
            )
            self.db.commit()
        return cur.rowcount

    def roster_since(self, cursor: int, *, limit: int = MAX_PAGE) -> list[StoredEvent]:
        return self._rows(
            "SELECT * FROM events WHERE kind = ? AND seq > ? ORDER BY seq LIMIT ?",
            (ROSTER_KIND, cursor, limit),
        )

    def latest_roster_seq(self) -> int:
        with self._lock:
            row = self.db.execute(
                "SELECT MAX(seq) AS seq FROM events WHERE kind = ?", (ROSTER_KIND,)
            ).fetchone()
        return int(row["seq"] or 0)

    # ---- deletion, the only kind there is --------------------------------

    def purge(
        self,
        agent: str,
        *,
        scope: str = "history",
        conversation_id: str | None = None,
        before_seq: int | None = None,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        """Real `DELETE`, not tombstones. "Delete their fields" is not satisfied
        by hiding text.

        Exactly one primitive with two optional filters, per §3:

        * `conversation_id` -- restrict to one conversation. Its row goes too,
          unless `before_seq` also narrows the range, in which case what is left
          of it is still a conversation.
        * `before_seq` -- exclusive. Events with a smaller `seq` go; phases that
          had already ended by that point go; a conversation row goes only when
          it is closed and nothing is left in it, because an open conversation
          with no events is still one he can answer.
        * neither -- everything of that agent's.

        `scope="everything"` additionally drops the agent row, and is **refused**
        rather than downgraded when a filter is present: dropping the identity
        while keeping some of its events would leave rows pointing at nothing.

        The `seq` sequence tolerates the holes this leaves. Clients find out via
        `history_generation`, which every real purge bumps.
        """
        if scope not in ("history", "everything"):
            raise ValueError(f"unknown purge scope {scope!r}")
        if scope == "everything" and (conversation_id or before_seq):
            raise ValueError(
                "scope='everything' cannot be narrowed by conversation_id or before_seq -- "
                "dropping the agent while keeping some of its rows would orphan them"
            )

        event_where = ["agent_name = ?"]
        event_params: list[Any] = [agent]
        if conversation_id:
            event_where.append("conversation_id = ?")
            event_params.append(conversation_id)
        if before_seq is not None:
            event_where.append("seq < ?")
            event_params.append(int(before_seq))
        event_clause = " AND ".join(event_where)

        with self._lock:
            counts = self.db.execute(
                f"SELECT COUNT(*) AS n, MIN(at) AS oldest FROM events WHERE {event_clause}",
                event_params,
            ).fetchone()
            events_hit = int(counts["n"])
            oldest_at = counts["oldest"]

            # Phases are bounded by wall-clock rather than by seq because they
            # have no seq of their own. `before_seq` is resolved to the moment
            # that event happened; a phase still running at that moment stays.
            cutoff_at: float | None = None
            if before_seq is not None:
                row = self.db.execute(
                    "SELECT MAX(at) AS at FROM events WHERE seq < ?", (int(before_seq),)
                ).fetchone()
                cutoff_at = row["at"]

            phase_where = ["agent_name = ?"]
            phase_params: list[Any] = [agent]
            if conversation_id:
                phase_where.append("conversation_id = ?")
                phase_params.append(conversation_id)
            if before_seq is not None:
                # No resolvable cutoff means no phase can be proven old enough.
                phase_where.append("(ended_at IS NOT NULL AND ended_at < ?)")
                phase_params.append(cutoff_at if cutoff_at is not None else float("-inf"))
            phase_clause = " AND ".join(phase_where)
            phases_hit = int(
                self.db.execute(
                    f"SELECT COUNT(*) AS n FROM phases WHERE {phase_clause}", phase_params
                ).fetchone()["n"]
            )

            conversations_hit, conversation_ids = self._conversations_to_drop(
                agent, conversation_id, before_seq
            )

            if dry_run:
                return {
                    "agent": agent,
                    "scope": scope,
                    "dry_run": True,
                    "conversations": conversations_hit,
                    "events": events_hit,
                    "phases": phases_hit,
                    "oldest_at": oldest_at,
                    "agent_removed": False,
                    "history_generation": self.history_generation(agent),
                }

            self.db.execute(f"DELETE FROM events WHERE {event_clause}", event_params)
            self.db.execute(f"DELETE FROM phases WHERE {phase_clause}", phase_params)
            for cid in conversation_ids:
                self.db.execute("DELETE FROM conversations WHERE id = ?", (cid,))

            agent_removed = False
            if scope == "everything":
                self.db.execute("DELETE FROM agents WHERE name = ?", (agent,))
                agent_removed = self.db.execute(
                    "SELECT COUNT(*) AS n FROM agents WHERE name = ?", (agent,)
                ).fetchone()["n"] == 0
                generation = 0
            else:
                self.db.execute(
                    "UPDATE agents SET history_generation = history_generation + 1, "
                    "updated_at = ? WHERE name = ?",
                    (time.time(), agent),
                )
                row = self.db.execute(
                    "SELECT history_generation AS g FROM agents WHERE name = ?", (agent,)
                ).fetchone()
                generation = int(row["g"]) if row else 0
            self.db.commit()

        return {
            "agent": agent,
            "scope": scope,
            "dry_run": False,
            "conversations": conversations_hit,
            "events": events_hit,
            "phases": phases_hit,
            "oldest_at": oldest_at,
            "agent_removed": agent_removed,
            "history_generation": generation,
        }

    def _conversations_to_drop(
        self, agent: str, conversation_id: str | None, before_seq: int | None
    ) -> tuple[int, list[str]]:
        """Which conversation rows a purge takes with it. Caller holds the lock."""
        if conversation_id and before_seq is None:
            rows = self.db.execute(
                "SELECT id FROM conversations WHERE agent_name = ? AND id = ?",
                (agent, conversation_id),
            ).fetchall()
        elif conversation_id:
            # Narrowed within one conversation: what is left of it is still a
            # conversation, so the row stays.
            return 0, []
        elif before_seq is None:
            rows = self.db.execute(
                "SELECT id FROM conversations WHERE agent_name = ?", (agent,)
            ).fetchall()
        else:
            rows = self.db.execute(
                "SELECT c.id AS id FROM conversations c WHERE c.agent_name = ? "
                "AND c.closed_at IS NOT NULL AND NOT EXISTS ("
                "  SELECT 1 FROM events e WHERE e.conversation_id = c.id AND e.seq >= ?)",
                (agent, int(before_seq)),
            ).fetchall()
        ids = [str(row["id"]) for row in rows]
        return len(ids), ids

    # ---- what /health is allowed to claim --------------------------------

    def stats(self) -> dict[str, Any]:
        """Only what was actually checked this call.

        `db_ok` is a real query, not the absence of an exception at boot: a
        database that has since gone read-only, been deleted underneath us or
        run the disk out has to read as not-ok here or this endpoint is lying in
        exactly the way it exists to stop.
        """
        out: dict[str, Any] = {"db_ok": False, "db_bytes": None, "disk_free": None}
        try:
            with self._lock:
                self.db.execute("SELECT COUNT(*) FROM sqlite_master").fetchone()
            out["db_ok"] = True
        except Exception as exc:  # noqa: BLE001 - the whole point is to report, not raise
            out["db_error"] = f"{type(exc).__name__}: {exc}"
            return out
        try:
            total = 0
            for suffix in ("", "-wal", "-shm"):
                candidate = Path(str(self.path) + suffix)
                if candidate.is_file():
                    total += candidate.stat().st_size
            out["db_bytes"] = total
        except OSError as exc:
            out["db_error"] = str(exc)
        try:
            out["disk_free"] = shutil.disk_usage(self.path.parent).free
        except OSError as exc:
            out["db_error"] = str(exc)
        return out
