# Server plan — agent channels, persistence, control, and the map

Status: **approved 2026-08-26**, implementation in progress.

This is the source of truth for the server-side work the redesigned iOS app needs.
It supersedes nothing; it is new work. Everything here was designed against the
running code and every claim about current behaviour was verified by reading it.

Two empirical spikes fed this plan and their findings are load-bearing:

- **SIGINT does not cancel a turn** — it terminates the process, in both tmux and
  headless modes. The only confirmed cancel-and-survive mechanism is a raw
  keystroke on the pty (`tmux send-keys -t <target> Escape`).
- **No hook payload carries a human-written summary.** Field list for
  `PreToolUse` is exactly `session_id, transcript_path, cwd, prompt_id,
  permission_mode, effort, hook_event_name, tool_name, tool_input, tool_use_id`.
  `PostToolUse` adds `tool_response` (full, untruncated) and `duration_ms`.
  `UserPromptSubmit` carries `prompt`. `Stop` carries `last_assistant_message`.
  Tested against Claude Code 2.1.241.

---

## 0. Current state, verified

- **Conversations carry no agent identity.** `Service.calls: dict[str, EventLog]`
  and `Service.call_opened` are keyed by a random 12-hex id. `agent` is used
  transiently in `/api/v1/say` and `/api/v1/call` routing but never written onto
  the conversation record.
- **Everything is in memory and reaped hourly** (`reap(older_than=3600)`, called
  from `/health`). Only closed conversations reap; an unanswered one lives until
  the process restarts, then is gone regardless.
- **Live/busy is already computed live, not cached.** `agents()` calls
  `hotline.ccsocks.discover()` per request, which validates a session by
  re-checking `/proc/<pid>/stat` start-time and the control socket. A crashed
  process therefore already reads as not-live with no polling lag. The real gap
  is that `busy` is the session's *self-reported* status on disk, which goes
  stale if a process hangs — that is a `stalled` flag, not a liveness problem.
- **A second death signal exists and is unused**: `Registry.Agent.completed_at`,
  an agent saying "done" deliberately. Today a clean finish and a crash both just
  vanish from the list identically.
- **`/api/v1/hangup` does not hang up.** `Service.hang_up()` cancels the daemon's
  own asyncio task awaiting `pool.ask()`. The agent keeps running untouched.
- **Phase/tool data reaches the daemon only via `Service.say()`'s `narrate()`
  callback**, i.e. only for turns the daemon itself initiated, and only as a bare
  tool name. There is no phase concept anywhere in hotline.
- **The stale agent list**: `ContentView` refreshes from `.task { }` and
  `.refreshable { }` only. `.task` runs once per `Store` identity, stable for the
  whole foregrounded lifetime. No timer, no scene-phase hook, no server push.
- **The `EventLog` cursor + long-poll design is sound and is kept.** Its only
  problems are that it is in-memory and capped at `MAX_EVENTS = 500` per
  conversation, so `gap`/`dropped` fire on any long-running channel.

---

## 1. Store

**SQLite via stdlib `sqlite3`**, WAL mode, under the same `XDG_STATE_HOME`
convention hotline's `Registry` already uses so existing backups pick it up
without a special case. Chosen for ordered, indexed, paginated queries over a
single global event sequence with zero new dependency and trivially safe
single-writer/many-reader access.

```sql
CREATE TABLE agents (
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

CREATE TABLE conversations (
  id TEXT PRIMARY KEY,
  agent_name TEXT NOT NULL REFERENCES agents(name),
  kind TEXT NOT NULL,                  -- 'ring' | 'say'
  opened_at REAL NOT NULL, closed_at REAL,
  waiting_since REAL,
  answered INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE events (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,   -- ONE global cursor space
  conversation_id TEXT REFERENCES conversations(id),
  agent_name TEXT NOT NULL,
  kind TEXT NOT NULL,
  phase_id TEXT,
  tool TEXT, text TEXT NOT NULL,
  via_subagent INTEGER NOT NULL DEFAULT 0,
  at REAL NOT NULL
);
CREATE INDEX events_agent_seq ON events(agent_name, seq);

CREATE TABLE phases (
  id TEXT PRIMARY KEY, agent_name TEXT NOT NULL, conversation_id TEXT,
  title TEXT NOT NULL, outcome TEXT,
  started_at REAL NOT NULL, ended_at REAL
);
```

**The load-bearing decision: one AUTOINCREMENT `seq` shared across every agent
and conversation**, not per-conversation as today. History and live feed become
the same `WHERE seq > ?` against one table, so "no gap, no duplicate" is a
property of `>` on a primary key rather than something the client reconciles.

---

## 2. The map — hooks nudge, the daemon tails the transcript

**Titles: from `UserPromptSubmit.prompt`.** No hook payload carries a
human-written summary; Strategy A is not buildable. A phase title is a ~60–80
char truncation of the user's prompt, **frozen at open and never updated** — a
title that shifts under a finger mid-scroll is worse than a duller one that
holds still. A separate `outcome` fills in on close from
`Stop.last_assistant_message`. Reads as ask-then-answer on a phone row.

**Architecture: hooks are a nudge, not a content channel.** The hook POSTs only
`{session_id, cwd, transcript_path, event}` — tiny, no secrets on the wire. The
daemon looks up `agents.transcript_offset`, reads forward, appends what is new,
advances the offset.

Why this and not hook-streams-content: **hotline already parses this exact file
in production.** `transcript.py`'s `read_since()` / `turn_in_flight()` read the
JSONL incrementally by byte offset and have already solved filtering
`isSidechain` subagent turns and using `parent_tool_use_id` to separate a nested
tool-driven turn from the real answer. Consequences: no truncation policy at the
wire, nothing sensitive over HTTP, and daemon downtime becomes a delayed read
rather than a permanent hole.

Extend `transcript.py` with `events_since(session_id, offset) -> list[TranscriptEvent]`
yielding structured records (user-turn / assistant-text / tool_use /
sidechain-tool_use, each with its `parent_tool_use_id` / `isSidechain` flags),
alongside the existing `read_since` rather than replacing it.

**Phase boundaries come from the transcript's own structure**, not hook fields: a
real user turn (`_is_real_user_turn` — `type: "user"` whose content is not a
`tool_result`) opens a phase; assistant `tool_use` blocks with matching
`parent_tool_use_id` and no `isSidechain` are its tool list; it closes on the
next real user turn or on Stop.

**Fail loudly, never silently empty.** `read_since`'s `except ValueError:
continue` is right for its existing job and wrong as the sole source of the map.
Track a parse-failure rate per read; if a read produces nothing recognisable,
**stop advancing that session's offset**, log it, and file into
`service.degradations` — the same mechanism `/health` already uses for a doorbell
that is quietly failing. A silently-empty map is the loopback-doorbell failure
shape and must not be reintroduced.

**The hook script** is fire-and-forget: ≈300 ms client timeout, blanket `except`,
always exits 0, plus an in-process 30 s backoff after a failure so a dead daemon
does not tax every tool call. It must never block or fail the tool call.

**A periodic safety poll** over known live sessions catches missed or failed
hook nudges.

**Correlation is direct.** `~/.claude/sessions/<pid>.json` records `sessionId`,
read in `ccsocks.py` as `LiveSession.session_id`, the same value
`Registry.Agent.session_id` keys on, originating as the CLI's own
`CLAUDE_CODE_SESSION_ID` (`cli.py`). So `hook.session_id == descriptor.sessionId
== Registry.Agent.session_id`. No cwd heuristic, no injected env var.
**Implementation step zero verifies this by dump-and-compare** — it is inference
from reading three files, not yet observed.

**Unattributable events are dropped loudly**: log a warning, increment an
`unattributed_hook_events` counter on `/health`. Never file into a phantom
bucket.

**Subagents nest under the parent phase**, not their own channel — they have no
`Registry` entry and no identity hotline treats as channel-worthy. Attributed via
the transcript's own `isSidechain` / `parent_tool_use_id` markers, and marked
`viaSubagent` in the wire type so the app can dim or indent them.

**Storage policy**: the `events` table keeps the tool name plus a ≈200-char
one-line summary of the primary argument. The authoritative full record stays
where it already lives, on disk in the transcript, untouched.

**Volume**: once the hook ships, every tool call from every agent on the box
persists. This is the dominant source of row growth and is precisely why §3's
purge surface exists.

---

## 3. Retention — a curated deletion surface, not a policy

Two distinct operations, not five.

**`retire`** — reversible, visibility only, a flag (`agents.retired_at`)
orthogonal to live/busy/dead. An agent can be live and retired at once. No
confirmation; nothing is destroyed.

**`purge`** — irreversible, real `DELETE`:

```
POST /api/v1/agents/purge
  {agent, scope: "history" | "everything",
   conversation_id?, before_seq?, dry_run?}
```

`scope="history"` deletes events and phases, keeps the agent record.
`scope="everything"` also drops the agent row. `conversation_id` or `before_seq`
narrow it. That one primitive with two optional filters covers
delete-a-conversation, delete-a-range and delete-it-all. **Per-event deletion is
explicitly not planned.**

**Real deletion, not tombstones** — "delete their fields" is not satisfied by
hiding text. The `seq` cursor tolerates holes. Clients learn via
`agents.history_generation`, bumped on every purge and carried on every roster
row and in the roster-events payload; a client seeing an unfamiliar generation
discards its whole local cache for that agent and refetches. A purge therefore
reaches the phone within one roster wake.

**Confirmation**: `dry_run: true` returns real counts
(`conversations, events, phases, oldest_at`) without deleting, so the sheet reads
"hotline-80 — 340 events since Aug 12" rather than a generic warning, then
hold-to-confirm before the real call.

**Local cache clearing is separate and non-destructive** — a settings-level
"free up space" that clears the on-device copy only and says in its own label
that it will re-download. Real deletion always goes through `purge`; the app
drops its local copy only as a side effect of that call succeeding.

**`/health` gets the only automatic guard**: `db_bytes` and a free-space estimate
via `shutil.disk_usage`. No automatic reaping — that is the point.

---

## 4. Control — server-declared capabilities

```swift
struct Capability: Codable {
    let id: String       // "kill" | "stop" | "retask" | "resume" | "new"
    let label: String
    let enabled: Bool
    let reason: String?
}
```

`Agent` gains `controls: [Capability]`; a small `globalControls` rides on
`/health` for `new`. The app hardcodes the endpoints and their shapes — an
ordinary client/server contract — but never `enabled`, `label` or `reason`.

**Why this matters here specifically**: the app is sideloaded on a free Apple
provisioning profile (7-day expiry, 3-device limit, no self-service removal), so
a reinstall is genuinely expensive. Anything the UI can show, enable, disable or
label must be answerable by the daemon at runtime.

Deliberately **not** a generic plugin system that renders arbitrary future verbs
sight-unseen — speculative generality for a single-user app with one developer on
both ends.

### `stop` — real in v1

New primitive in `tmuxen.py` (which today has only `exists`, `kill`, `capture`,
`spawn`):

```python
async def interrupt(target: str) -> None:
    """tmux send-keys -t <target> Escape — the only confirmed in-band way to
    cancel a turn without ending the process. Not a signal; SIGINT kills."""
```

Gated exactly as `terminate()` already is (refuse if the resolved session is
hotline itself, reusing the existing check). `/api/v1/agents/stop {agent}` is a
thin wrapper.

`interrupt()` is the **only** place that knows *how* to cancel; the endpoint calls
it by name and knows nothing of tmux or ptys, so a future socket-level cancel is a
one-function swap. (`ccsocks.py` has no cancel message today — `inject()` only
ever sends `{"type": "user", ...}`.)

**`enabled` is computed per agent, never hardcoded.** The pty cancel needs a pty;
a headless `claude -p` session has none. On every roster call, compute from
`LiveSession.tmux is not None` **and** `tmuxen.exists(...)` still true at request
time — same real-time recheck as liveness. Reasons: `"not running"`, or
`"running headless — its turn can't be interrupted, only killed"`.

**Debounce**: `Service` tracks `last_stop_at[agent]`; a repeat `stop` within ~2 s
returns 409 "already interrupting". Sub-200 ms double-Escape behaviour is
unverified and this avoids designing around a guess; it also makes a client
retry-on-timeout safe.

**Server-side enforcement is independent of the declaration** — `/api/v1/agents/stop`
returns 409 on its own even if a stale client shows it enabled.

### stop-then-retask is composed server-side

```
POST /api/v1/agents/retask {agent, text, stop_first: bool = false}
```

Two HTTP calls from a phone is worse than the status quo in one specific way: if
the interrupt lands and the network drops the second call, the agent is cancelled
with nothing queued to replace it. One request makes it atomic from the phone's
side — the retask either starts now or starts after the current turn, never
neither. `stop_first` is honoured only when that agent's `stop` is enabled, and
is refused rather than silently downgraded when it is not.

### Labels

| id | label | enabled when | disabled `reason` |
|---|---|---|---|
| `stop` | Stop | live/busy, has a tmux target | see above |
| `kill` | Kill | live (any status) | `"not running"` |

UI copy must make the asymmetry explicit rather than implying two strengths of
the same thing: stop interrupts the current turn and the session survives and can
take new work; kill ends the session and it only returns through Resume, and only
if it left a handoff or a transcript. Kill is the destructive one and gets the
confirmation.

**`hangup`'s honesty fix stands**: `process_stopped: false` always, plus a code
comment naming the limit. It only ends the daemon's own wait.

---

## 5. Collapse — `conversation_id` becomes a grouping key

```
POST /api/v1/agents/feed  {agent, since, wait}
→ {agent, events: [...], cursor, closed}
```

Same shape and long-poll semantics as today's `/api/v1/events`, filtered by
`agent_name`, sharing the one global `seq`. **`/api/v1/events` is kept
unchanged** so the app currently installed keeps working.

App-side changes: `Link.moments(conversation:)` → `Link.moments(agent:)`;
`Store.follow(_ conversation:)` → `Store.follow(_ agent:)`.

**`Waiting.conversation` does not go away** — `/api/v1/reply` still targets one
specific unanswered conversation, because that is what unblocks one particular
`hotline-call` invocation. Conversation stops being a *display* concept, not an
identifier.

Consequence worth designing for: an agent's channel now interleaves a ring's Q&A,
a delegated `say`, and hook-reported tool events, ordered by `seq`. `Moment.id`
moving to the global seq is fine — still unique, still monotonic. `Store.apply`'s
local-echo dedup needs no change; it only compares within displayed moments.

---

## 6. Endpoints

| Method & path | Request | Response | For |
|---|---|---|---|
| `GET /health` | — | `+db_ok, db_bytes, disk_free, globalControls, unattributed_hook_events` | unchanged contract, extended |
| `POST /api/v1/call` | unchanged | unchanged | ring |
| `POST /api/v1/say` | unchanged | unchanged | delegate; now persists `agent_name` |
| `POST /api/v1/reply` | unchanged | unchanged | answer a blocked conversation |
| `POST /api/v1/hangup` | unchanged | `+process_stopped: false` | end the daemon's wait, honestly labelled |
| `POST /api/v1/events` | unchanged | unchanged | conversation-scoped feed, kept for compat |
| `POST /api/v1/agents` | unchanged | `+blocked, blockedSince, state, stalled, deadReason, retired, historyGeneration, controls` | roster |
| `POST /api/v1/agents/roster-events` | `{since, wait}` | `{events, cursor}` | invalidation tick; fixes the stale list |
| `POST /api/v1/agents/feed` | `{agent, since, wait}` | `{agent, events, cursor, closed}` | agent-scoped live feed |
| `POST /api/v1/agents/history` | `{agent, before, limit≤200}` | `{events, oldest_seq, newest_seq, has_more}` | paginated backward history |
| `POST /api/v1/agents/purge` | see §3 | counts | curated deletion |
| `POST /api/v1/agents/retire` | `{agent, retired: bool}` | `{agent, retired}` | visibility only |
| `POST /api/v1/agents/stop` | `{agent}` | `{agent, interrupted}` | cancel the current turn, session survives |
| `POST /api/v1/agents/kill` | `{agent}` | `{agent, outcome}` | `SIGTERM`→`SIGKILL` via `router.kill_session()` |
| `POST /api/v1/agents/retask` | `{agent, text, stop_first}` | `{agent, delivered, queued}` | `ccsocks.inject()`, optionally after an interrupt |
| `POST /api/v1/agents/resume` | `{agent, cwd?}` | `{agent, session, from_handoff}` | shared `_resume()` refactored out of `cli.py` |
| `POST /api/v1/agents/new` | `{task, cwd?, name?}` | `{agent, session}` | fresh session |
| `POST /api/v1/hook` | `{session_id, cwd, transcript_path, event}` | `{}` | the nudge; fire-and-forget |

---

## 7. Implementation order

Each step lands and passes tests on its own. None requires the app to ship in
lockstep.

0. **Verify the session-id correlation** by dump-and-compare: one real session
   with the hook installed, one `UserPromptSubmit` payload's `session_id`,
   compared byte-for-byte against that session's `~/.claude/sessions/<pid>.json`
   `sessionId`. Blocks only the hook work.
1. `store.py` — schema above behind a thin interface (`open_conversation`,
   `append_event`, `history`, `since`). No daemon wiring. Own tests.
2. Swap `Service.calls` / `call_opened` to write through the store, keeping
   `EventLog`'s long-poll wake as an in-memory index *over* the persisted rows —
   reuse the concurrency primitive that already works rather than replacing it.
3. Resolve and persist `agent_name` on every conversation at open time in
   `place()` / `say()`, reusing the lookup already in `_bind()`. This is what
   makes channels-per-agent real.
   - 3a. `retired_at`, `history_generation`, `purge` (with `dry_run`),
     retire/unretire.
   - 3b. `/api/v1/agents/feed`, alongside the untouched `/api/v1/events`.
4. `/api/v1/agents/history` and `/api/v1/agents/roster-events`.
5. Blocked-pin fields on the roster: aggregate `waiting_since` across each
   agent's open unanswered conversations.
6. `state` / `stalled` / `deadReason` from `Registry.Agent.completed_at`,
   `ccsocks.discover()` and `agents.last_tool_at`. No new heartbeat loop —
   liveness stays a per-request check, which is stronger than an interval.
7. `transcript.events_since()`, `/api/v1/hook`, the hook script, phase
   reconstruction, the safety poll, and the loud parse-failure path. Backoff and
   truncation limits are acceptance criteria, not follow-ups.
8. Control endpoints. `tmuxen.interrupt()` first, then `stop`, `kill`, `retask`,
   `new`. `resume` after refactoring `_resume()` out of `cli.py` into something
   both callers use — its own commit, with tests, before wiring the route. The
   `Capability` list ships with them, not after.
9. `hangup`'s honesty fix.

---

## 8. Test plan

**Changed:**
- `test_open_calls_ignores_closed_ones_and_reap_drops_them` — retarget at the
  store. Keep the shape: inject a synthetic old timestamp, never sleep.
- `test_the_event_feed_replays_from_a_cursor_without_loss` — unchanged contract,
  keep as the conversation-scoped regression.
- Roster and conversation shape tests — extend assertions, do not touch existing
  ones; this doubles as an app-compat regression.
- `test_the_agent_list_survives_a_missing_registry` — add a sibling for a missing
  DB file at boot (create-if-missing, not fatal).

**Added:**
- **The history/stream seam.** Write N synthetic events straight into the store.
  `history(agent, before=None, limit=k)` for `k<N`, note `newest_seq`. Then
  `since(agent, cursor=newest_seq)`. Assert the two sets are disjoint and their
  union is exactly all N by `seq`. Pure synchronous DB assertion, zero timing.
- **Persistence across restart** — two store instances against the same path in
  one test; write with the first, assert the second sees it.
- **Dead-agent detection without sleeping** — fake `discover()`/Registry doubles,
  one that has the pid and one that does not, assert `state` flips on the next
  call. For `stalled`, inject `last_tool_at = now - THRESHOLD - 1` directly, the
  pattern the existing reap test already uses.
- **Roster-events invalidation** — append a state change synthetically, assert it
  appears with `since=0`; assert `since=<that seq>` blocks (bounded
  `asyncio.wait_for`) until a second injected change wakes it.
- **Purge/retire** — `dry_run=true` returns correct counts and deletes nothing;
  `dry_run=false` removes rows and bumps `history_generation`;
  `scope="everything"` drops the agent row; retire round-trips without touching
  history.
- **`history_generation` mismatch** triggers a full recache — assert the field
  changes across a purge.
- **Control against fakes, never real processes** — assert the daemon called the
  right function with the right argument. Never spawn `claude`, never signal,
  never shell out to real tmux from the suite.
- **`stop` specifics** — `enabled=false` with the right `reason` for a headless
  session and separately for a not-live one; 409 in the headless case even when a
  hand-built stale roster claims enabled; two rapid calls invoke `interrupt`
  exactly once and the second gets 409.
- **`retask` with `stop_first=true`** — assert `interrupt` then `inject`, in that
  order; and that `stop_first` is refused, not silently downgraded, when `stop`
  is not enabled.
- **The hook is fire-and-forget** — under a simulated daemon timeout (socket
  accepted, never answered) it still exits 0 within its own short deadline. This
  is the one place a bounded real timeout is legitimate, because the property
  under test *is* boundedness.

**Standing rule for this suite**: a test that needs to wait polls a predicate
with a bound (the `eventually()` helper in `test_sip.py`). No bare sleeps. This
project has already been bitten by a race-condition flake; do not add another.

---

## 9. Telemetry readouts and the compact button

Added 2026-08-26 on Bogdan's call, after the `Telemetry` design concept:
*"i like all the telemetry especially the one inside agents. I want that
implemented absolutely along side a compact button which then stops the agent
compacts and makes him continue."*

### 9.1 The rule these inherit

Every animated quantity must encode a real number. If a readout cannot be
sourced from something the server actually observes, it does not ship. A pulse
that means nothing is the failure mode this project already rejected once.

### 9.2 Where each readout comes from

All of these fall out of §2's transcript tailing — the daemon is already reading
every assistant message and every `tool_use` with timestamps, so the metrics are
a projection of data it now has, not a new ingest path.

| Readout | Source | Honest? |
|---|---|---|
| **tokens/sec** | assistant text length delta ÷ wall time between transcript reads | approximate (characters, not true tokenizer counts) — must be labelled as a rate, never as a billing figure |
| **tool-call ticks** | each `tool_use` record's timestamp | exact |
| **90 s sparkline ring** | rolling window over the same samples | exact |
| **time blocked** | `conversations.waiting_since` | exact |
| **phase progress** | open phase's `started_at` vs the agent's own history | exact |
| **context consumed** | `statusLine` payload's `context_window.used_percentage` — see §9.7 | exact, computed by the CLI itself |

A **dead agent must be flat and still**, not idling — that is a correctness
requirement on the data, not a styling note.

### 9.3 Wire shape

The server exposes samples, not curves. The app builds the sparkline from the
feed it is already streaming; on a hard refresh it backfills from
`/api/v1/agents/history`, whose events already carry `at`. No new endpoint.

`Agent` gains a small live block:

```swift
struct Vitals: Codable {
    let tokensPerSec: Double      // rolling, characters-derived, see 9.2
    let toolsPerMin: Double
    let lastToolAt: Double?
    let blockedFor: Double?       // seconds, nil when not blocked
    let contextUsed: Double?      // 0…1, nil when unknown — see 9.4
}
```

`contextUsed` is **optional on purpose**. If 9.4 finds no honest source it ships
`nil` forever and the app renders no context gauge, rather than a made-up one.

### 9.4 Spike required before the compact button is meaningful

> **RESOLVED 2026-08-26 — see §9.7. Both unknowns below were answered
> empirically. §9.7 supersedes this section; it is kept for the reasoning.**

Two unknowns, both empirically checkable, neither safe to assume:

1. **Is there any real source for context consumption of a live session?**
   Candidates to check: the session descriptor at `~/.claude/sessions/<pid>.json`,
   the transcript JSONL (per-message usage fields), whatever the CLI's own
   statusline reads. If none exists, `contextUsed` stays `nil` — and the compact
   button then has no gauge to justify itself, which is worth knowing before
   building the UI around it.

2. **How does a slash command actually get into a live session?**
   `ccsocks.inject()` sends `{"type": "user", ...}`. It is unknown whether text
   beginning with `/compact` arriving that way is executed as a slash command or
   inserted as literal text. The pty path (`tmux send-keys -t <target> "/compact"
   Enter`) goes through the CLI's own input handling and is far more likely to be
   interpreted correctly — it is the same channel the confirmed `Escape`
   interrupt uses. **Verify which works. Do not ship a compact button that types
   a literal string into a prompt.**

### 9.5 The endpoint

```
POST /api/v1/agents/compact {agent, then?: str}
→ {agent, interrupted, compacted, resumed}
```

Composed server-side for the same reason `retask {stop_first}` is: three separate
calls from a phone means a dropped connection can leave the agent interrupted and
idle, or compacted and never restarted. One request, one outcome.

Sequence:

1. `tmuxen.interrupt(target)` — the confirmed Escape cancel. Reuses §4's
   primitive and its debounce.
2. Issue `/compact` by whichever mechanism 9.4 confirms.
3. Wait for compaction to finish. **Detection must be observed, not timed** —
   watch the transcript / session descriptor for the session returning to idle.
   A fixed sleep here is exactly the kind of green-check-that-measures-nothing
   this project has already been burned by. If no reliable completion signal
   exists, the endpoint returns `compacted: true, resumed: false` and says so
   rather than firing the continuation into a busy session.
4. Inject the continuation — `then` if supplied, otherwise a default that tells
   the agent to pick up where it left off.

Every field in the response reports what actually happened. `resumed: false` is a
valid, honest outcome and the app must render it as such.

### 9.6 Capability

`compact` joins §4's `Capability` list, `enabled` computed exactly like `stop` —
it needs the same pty, so a headless session cannot be compacted this way and
must say so in its `reason`. It is disabled, not hidden, when unavailable.

### 9.7 Spike results — 2026-08-26, Claude Code 2.1.241

All three questions resolved by direct observation against throwaway sessions.
These findings supersede §9.4 and settle §2's correlation assumption.

#### Correlation is confirmed, byte-for-byte

`hook.session_id` == `~/.claude/sessions/<pid>.json`'s `sessionId` == the string
`transcript.transcript_path(session_id)` resolves to. Verified on a live session
by direct comparison, not inference. `Registry.Agent.session_id` is a plain
constructor param populated from `LiveSession.session_id` — the same descriptor
field — so it is a pass-through, not a third inference hop.

**§2's step zero is discharged.** No cwd heuristic, no injected env var.

#### `contextUsed` has an honest source — the statusLine payload

Not the transcript, not the session descriptor. Claude Code's `statusLine`
command receives JSON on stdin containing:

```json
"context_window": {
  "total_input_tokens": 46638, "total_output_tokens": 166,
  "context_window_size": 1000000,
  "current_usage": {"input_tokens": 2, "output_tokens": 166,
                    "cache_creation_input_tokens": 1978,
                    "cache_read_input_tokens": 44658},
  "used_percentage": 5, "remaining_percentage": 95
}
```

`used_percentage / 100` **is** `contextUsed`, already computed by the CLI. No
tokenizer, no window-size guessing. It fires multiple times per turn — idle,
mid-turn, and at Stop.

Two facts that constrain the implementation:

- **It is `null` before the first turn** (nothing sent yet), so `contextUsed`
  stays `nil` until a first sample arrives. The app must handle that, not treat
  it as zero.
- **`statusLine` is a single per-session slot.** Consuming it means hotline
  installs itself as that command. **If a statusline is already configured it
  must be wrapped, not replaced** — run the existing command, pass its stdout
  through verbatim, and report to the daemon as a side effect. Bogdan's terminal
  must look identical afterwards. This is a shared-config change of the same
  class as the hook.

Ruled out, with evidence: the session descriptor carries no usage or context
fields at all (only pid, sessionId, cwd, tmux, status, timestamps). Transcript
assistant messages *do* carry exact `usage` counts, but nothing anywhere gives
the window size to divide by — `context_window_size` appears only in the
statusLine payload.

#### `/compact` must go through the pty. `inject()` does not work.

**`ccsocks.inject("/compact")` delivers literal text, not a command.** The
transcript shows it landing as an ordinary peer user turn, and the model replied
that it could not act on it because no tool exposed to it triggers compaction. No
compaction occurred. This is precisely the "types a literal string into a prompt"
failure §9.4 warned about, and it is what would have shipped on the obvious
implementation.

**`tmux send-keys -t <target> "/compact"` then `Enter` executes it for real** —
the CLI's slash-command autocomplete fires and the pane shows a genuine
"Compacting conversation… NN%" progress bar. Same channel as the confirmed
`Escape` interrupt, which is why §9.6 gating compact to pty-backed sessions is
correct rather than merely cautious.

#### Compaction completion is observable — two independent signals

1. The session descriptor's `status` flips `busy` → `idle`
   (`ccsocks.status_of(pid)`) exactly when compaction finishes.
2. The transcript gains an exact structural marker:

```json
{"type": "system", "subtype": "compact_boundary",
 "content": "Conversation compacted",
 "compactMetadata": {"trigger": "manual", "preTokens": 48027, "postTokens": 4070,
                     "cumulativeDroppedTokens": 43957, "durationMs": 71104}}
```

followed immediately by a `user` record with `"isCompactSummary": true` carrying
the summary text. **This is in the file §2 already tails**, so it needs no new
ingest path.

So §9.5's step 3 needs no fixed sleep. Watch for either signal; prefer the
transcript marker, since it also yields real numbers.

**Use those numbers.** `preTokens` → `postTokens` and `durationMs` are exactly
the kind of true quantity §9.1 demands, so the compact button should report what
it actually did — "48k → 4.1k in 71s" — rather than a generic success state.

**Proof of life confirmed**: after compaction the session accepted an injected
message and answered normally, same as the SIGINT-survives finding.

#### Revised sequence for `/api/v1/agents/compact`

1. `tmuxen.interrupt(target)` — Escape.
2. `tmux send-keys -t <target> "/compact"` then `Enter`. **Not `inject()`.**
3. Wait on the `compact_boundary` transcript record (or descriptor `idle`), never
   a timer. Capture `preTokens`, `postTokens`, `durationMs`.
4. Inject the continuation via `ccsocks.inject()` — `then` if supplied, else a
   default to pick up where it left off. `inject()` is correct here, because a
   continuation genuinely *is* a user message.

Response carries `{interrupted, compacted, resumed, preTokens, postTokens,
durationMs}`. `resumed: false` remains a valid honest outcome.
