"""The map: hooks nudge, the daemon tails the transcript, phases come out.

Everything here drives real code against a real (throwaway) `~/.claude` tree
rather than mocking `transcript.events_since`. The point of §2's architecture is
that hotline's existing parser is the one doing the reading; a suite that faked
it would be testing the fake.

`hotline.ccsocks.discover` and `hotline.agents.Registry` are still doubles, for
the reason `test_agent_channels.py` gives: the real ones report whichever Claude
sessions happen to be running on archserver while the suite runs.

Nothing here sleeps except `test_the_hook_gives_up_on_a_daemon_that_never_answers`,
where boundedness IS the property under test (§8).
"""

from __future__ import annotations

import asyncio
import json
import socket
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

import pytest

pytest.importorskip(
    "hotline.httpd",
    reason="hotline not on sys.path -- run with PYTHONPATH=/home/bodas/data/hotline/src",
)

import hotline.agents
import hotline.ccsocks

from hotline_ios import hooks, ingest
from hotline_ios.daemon import Service, build_server
from hotline_ios.ring.loopback import LoopbackTransport
from hotline_ios.store import Store

SID = "sess-map-1"


class Reply:
    def __init__(self, text): self.text = text; self.notice = ""


class FakePool:
    async def ask(self, key, text, narrator=None, timeout=None, origin=None):
        return ("fresh", Reply("ok"))


class Record:
    def __init__(self, name, session_id, task="", completed_at=None):
        self.name = name
        self.session_id = session_id
        self.task = task
        self.completed_at = completed_at
        self.declared_at = 1000.0


class Session:
    def __init__(self, session_id, name="", cwd="/tmp", status="idle"):
        self.session_id = session_id
        self.name = name or session_id[:8]
        self.cwd = cwd
        self.status = status


@pytest.fixture
def claude_home(tmp_path, monkeypatch):
    """A throwaway `~/.claude`, pointed at by the same env var the real hooks use."""
    home = tmp_path / "claude"
    (home / "projects" / "-fake").mkdir(parents=True)
    (home / "sessions").mkdir(parents=True)
    monkeypatch.setenv("HOTLINE_CLAUDE_HOME", str(home))
    monkeypatch.setenv("HOTLINE_RUNTIME", str(tmp_path / "run"))
    return home


@pytest.fixture(autouse=True)
def doubles(monkeypatch):
    state = {"records": [], "sessions": []}

    class FakeRegistry:
        def __init__(self, *_a, **_k):
            self.agents = {r.session_id: r for r in state["records"]}

        def by_name(self, name):
            wanted = name.strip().lower()
            return next((r for r in state["records"] if r.name.lower() == wanted), None)

    monkeypatch.setattr(hotline.agents, "Registry", FakeRegistry)
    monkeypatch.setattr(hotline.ccsocks, "discover", lambda *_a, **_k: list(state["sessions"]))
    return state


# ---- transcript builders -------------------------------------------------

_CLOCK = [1_800_000_000.0]


def _stamp():
    _CLOCK[0] += 1.0
    from datetime import UTC, datetime

    return datetime.fromtimestamp(_CLOCK[0], UTC).isoformat().replace("+00:00", "Z")


def prompt(text):
    return {"type": "user", "isSidechain": False, "timestamp": _stamp(),
            "message": {"role": "user", "content": text}}


def says(text):
    return {"type": "assistant", "isSidechain": False, "timestamp": _stamp(),
            "message": {"role": "assistant", "content": [{"type": "text", "text": text}]}}


def calls(tool, arguments, sidechain=False):
    return {"type": "assistant", "isSidechain": sidechain, "timestamp": _stamp(),
            "message": {"role": "assistant", "content": [
                {"type": "tool_use", "name": tool, "id": "t", "input": arguments}]}}


def compacted(pre, post, ms):
    return {"type": "system", "subtype": "compact_boundary", "isSidechain": False,
            "timestamp": _stamp(), "content": "Conversation compacted",
            "compactMetadata": {"trigger": "manual", "preTokens": pre, "postTokens": post,
                                "cumulativeDroppedTokens": pre - post, "durationMs": ms}}


def write(home, session_id, entries, *, subagent=None):
    if subagent is None:
        path = home / "projects" / "-fake" / f"{session_id}.jsonl"
    else:
        directory = home / "projects" / "-fake" / session_id / "subagents"
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"{subagent}.jsonl"
    with path.open("a") as fh:
        for entry in entries:
            fh.write(json.dumps(entry) + "\n")
    return path


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def post(port, path, payload, timeout=10):
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


def get(port, path, timeout=10):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as response:
        return json.loads(response.read())


async def eventually(predicate, *, within: float = 2.0) -> bool:
    """Poll a predicate to a deadline; the `test_sip.py` helper."""
    deadline = asyncio.get_running_loop().time() + within
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.01)
    return predicate()


def declared(doubles, name=" mapper", session_id=SID):
    doubles["records"] = [Record(name.strip(), session_id, task="mapping")]
    doubles["sessions"] = [Session(session_id, name=name.strip(), status="busy")]
    return name.strip()


# ---- what a phase is ------------------------------------------------------


async def test_a_turn_becomes_a_phase_with_its_tools_under_it(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [
        prompt("Fix the failing integration test in the payments module"),
        calls("Bash", {"command": "pytest -q tests/test_payments.py"}),
        calls("Edit", {"file_path": "/srv/payments/charge.py", "old_string": "a"}),
        says("Fixed it -- the mock clock was a second behind."),
    ])
    service = Service(LoopbackTransport(), FakePool())

    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})

    phases = service.store.phases(name)
    assert len(phases) == 1
    assert phases[0]["title"] == "Fix the failing integration test in the payments module"
    assert phases[0]["outcome"] == "Fixed it -- the mock clock was a second behind."
    assert phases[0]["ended_at"] is not None

    events = service.store.since(name, 0)
    assert [(e.kind, e.tool) for e in events] == [
        ("phase", None), ("tool", "Bash"), ("tool", "Edit"), ("outcome", None)
    ]
    # §2's storage policy: the tool name plus a one-line summary of the primary
    # argument. The full record stays on disk in the transcript.
    assert events[1].text == "pytest -q tests/test_payments.py"
    assert events[2].text == "/srv/payments/charge.py"
    assert all(e.phase_id == phases[0]["id"] for e in events)


async def test_the_title_is_frozen_at_open_and_never_rewritten(claude_home, doubles):
    """§2. A title that shifts under a finger mid-scroll is worse than a duller
    one that holds still, so what arrives later is the separate `outcome`."""
    name = declared(doubles)
    long_prompt = (
        "Investigate why the nightly build started failing on Tuesday and work out "
        "whether the toolchain bump is responsible"
    )
    write(claude_home, SID, [prompt(long_prompt), calls("Bash", {"command": "git log"})])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    opened = service.store.phases(name)[0]
    assert 60 <= len(opened["title"]) <= 81
    assert opened["title"].startswith("Investigate why the nightly build started failing")
    assert opened["title"].endswith("…")
    assert opened["outcome"] is None

    write(claude_home, SID, [says("The toolchain bump is responsible.")])
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})
    closed = service.store.phases(name)[0]
    assert closed["title"] == opened["title"]
    assert closed["outcome"] == "The toolchain bump is responsible."


async def test_a_second_prompt_closes_the_first_phase_and_opens_another(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [
        prompt("first job"), calls("Read", {"file_path": "/a"}), says("first done"),
        prompt("second job"), calls("Read", {"file_path": "/b"}),
    ])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})

    phases = sorted(service.store.phases(name), key=lambda p: p["started_at"])
    assert [p["title"] for p in phases] == ["first job", "second job"]
    assert phases[0]["outcome"] == "first done"
    assert phases[0]["ended_at"] is not None
    assert phases[1]["ended_at"] is None


async def test_a_subagents_tools_nest_under_the_parent_phase(claude_home, doubles):
    """§2: subagents have no Registry entry and no identity hotline treats as
    channel-worthy, so they nest and are marked rather than getting a channel.

    On Claude Code 2.1.241 they are in their own file, which is why this writes
    one; reading only the main transcript would make `viaSubagent` dead code."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("delegate the search"), calls("Agent", {"description": "look"})])
    write(claude_home, SID, [calls("Grep", {"pattern": "TODO"}, sidechain=True)],
          subagent="agent-aaa")
    write(claude_home, SID, [says("found three")])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})

    phases = service.store.phases(name)
    assert len(phases) == 1, "a subagent must not open a channel or a phase of its own"
    events = service.store.since(name, 0)
    by_tool = {e.tool: e for e in events if e.kind == "tool"}
    assert by_tool["Agent"].via_subagent is False
    assert by_tool["Grep"].via_subagent is True
    assert by_tool["Grep"].phase_id == phases[0]["id"]
    assert by_tool["Grep"].as_agent_json()["viaSubagent"] is True


async def test_a_subagents_tools_still_nest_when_they_arrive_after_the_phase_closed(
    claude_home, doubles
):
    """Measured end to end, and the reason `phase_at` exists.

    A subagent's file is written after the parent's Stop, and a background one
    outlives the parent's turn entirely -- so its tool calls are never in the
    store while the phase that spawned them is still open. Without the fallback
    every `viaSubagent` row lands unphased, which is precisely what §2 asked for
    nesting to prevent."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("delegate it"), calls("Agent", {"description": "look"})])
    write(claude_home, SID, [says("delegated; it is still running")])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})
    phase = service.store.phases(name)[0]
    assert phase["ended_at"] is not None

    # Only now does the subagent's own file appear.
    write(claude_home, SID, [calls("Glob", {"pattern": "*.sh"}, sidechain=True)],
          subagent="agent-late")
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})

    late = next(e for e in service.store.since(name, 0) if e.tool == "Glob")
    assert late.via_subagent is True
    assert late.phase_id == phase["id"]
    assert len(service.store.phases(name)) == 1


async def test_a_subagents_own_prompt_and_prose_are_not_the_parents(claude_home, doubles):
    """The trap `transcript.read_since` was written for: a subagent's internal
    report is not the parent's answer."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("real question")])
    write(claude_home, SID, [
        {"type": "user", "isSidechain": True, "timestamp": _stamp(),
         "message": {"role": "user", "content": "subagent instructions"}},
        {"type": "assistant", "isSidechain": True, "timestamp": _stamp(),
         "message": {"role": "assistant",
                     "content": [{"type": "text", "text": "subagent chatter"}]}},
    ], subagent="agent-bbb")
    write(claude_home, SID, [says("the real answer")])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})

    phases = service.store.phases(name)
    assert [p["title"] for p in phases] == ["real question"]
    assert phases[0]["outcome"] == "the real answer"


async def test_a_compaction_lands_with_its_real_numbers(claude_home, doubles):
    """§9.1: every quantity shown has to encode a real one. These are computed by
    the CLI itself, so the row says what it actually did."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("keep going"), compacted(48027, 4070, 71104)])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})

    row = next(e for e in service.store.since(name, 0) if e.kind == "compact")
    assert "48027" in row.text and "4070" in row.text and "71.1s" in row.text


async def test_records_the_cli_wrote_for_the_user_do_not_open_phases(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [
        prompt("<task-notification>\n<task-id>x</task-id>"),
        prompt("<command-name>/model</command-name>"),
        prompt("Base directory for this skill: /home/bodas/.claude/skills/x"),
        prompt("what he actually typed"),
    ])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "UserPromptSubmit"})
    assert [p["title"] for p in service.store.phases(name)] == ["what he actually typed"]


# ---- the offset ----------------------------------------------------------


async def test_a_second_nudge_reads_only_what_is_new(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [prompt("go"), calls("Bash", {"command": "one"})])
    service = Service(LoopbackTransport(), FakePool())
    first = await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    assert first["events"] == 2
    offset, _ = service.store.read_position(name)
    assert offset > 0

    again = await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    assert again["events"] == 0

    write(claude_home, SID, [calls("Bash", {"command": "two"})])
    third = await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    assert third["events"] == 1
    assert [e.text for e in service.store.since(name, 0) if e.kind == "tool"] == ["one", "two"]


async def test_concurrent_nudges_do_not_write_the_same_event_twice(claude_home, doubles):
    """A PreToolUse and the Stop behind it overlap constantly. Both would read
    from the same stored offset without the per-agent lock."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("go"), calls("Bash", {"command": "one"}), says("done")])
    service = Service(LoopbackTransport(), FakePool())
    await asyncio.gather(*[
        service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
        for _ in range(6)
    ])
    tools = [e for e in service.store.since(name, 0) if e.kind == "tool"]
    assert len(tools) == 1
    assert len(service.store.phases(name)) == 1


async def test_a_tool_call_is_the_only_thing_that_sets_last_tool_at(claude_home, doubles):
    """`stalled` is only meaningful because `last_tool_at` comes from observation
    rather than from the session's own word for itself."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("go")])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "UserPromptSubmit"})
    assert service.store.agent(name)["last_tool_at"] is None

    write(claude_home, SID, [calls("Bash", {"command": "x"})])
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    assert service.store.agent(name)["last_tool_at"] is not None


# ---- failing loudly ------------------------------------------------------


async def test_an_unreadable_transcript_holds_the_offset_and_says_so(claude_home, doubles):
    """§2: a silently-empty map is the loopback-doorbell failure shape. A read
    that produces nothing recognisable must be retried loudly, not skipped."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("go"), calls("Bash", {"command": "one"})])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    good_offset, _ = service.store.read_position(name)

    path = claude_home / "projects" / "-fake" / f"{SID}.jsonl"
    with path.open("a") as fh:
        fh.write("}}} not json at all\nnor this\n")

    answer = await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    assert answer["ok"] is False
    assert service.store.read_position(name)[0] == good_offset, "the offset must not advance"
    assert service.hook_parse_failures == 1
    assert name in service.ingest_stalled
    assert any("unreadable" in note for note in service.degradations)

    # And it recovers: once the file parses again the offset moves and the stall
    # clears, rather than needing a restart.
    path.write_text(path.read_text().replace("}}} not json at all\nnor this\n", ""))
    write(claude_home, SID, [calls("Bash", {"command": "two"})])
    assert (await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"}))["ok"]
    assert name not in service.ingest_stalled


async def test_an_unattributable_nudge_is_dropped_loudly_not_filed_under_a_guess(claude_home):
    """§2. Never file into a phantom bucket."""
    service = Service(LoopbackTransport(), FakePool())
    answer = await service.hook({"session_id": "belongs-to-nobody", "cwd": "/tmp",
                                 "event": "Stop"})
    assert answer["ok"] is False
    assert service.unattributed_hook_events == 1
    assert service.store.agents() == []
    assert service.store.latest_seq() == 0


async def test_health_reports_the_hook_counters(claude_home, doubles):
    declared(doubles)
    write(claude_home, SID, [prompt("go")])
    service = Service(LoopbackTransport(), FakePool())
    service.ring_ready = True
    port = free_port()
    server = build_server(service, "127.0.0.1", port)
    await server.start()
    try:
        await service.hook({"session_id": SID, "cwd": "/tmp", "event": "Stop"})
        await service.hook({"session_id": "nobody", "cwd": "/tmp", "event": "Stop"})
        health = await asyncio.to_thread(get, port, "/health")
        assert health["hook_events"] == 2
        assert health["unattributed_hook_events"] == 1
        assert health["hook_parse_failures"] == 0
        assert health["ingest_stalled"] == []
    finally:
        await server.close()


# ---- over HTTP, and the poll ---------------------------------------------


async def test_the_hook_endpoint_files_a_phase_end_to_end(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [
        prompt("ship the release"), calls("Bash", {"command": "make release"}), says("shipped"),
    ])
    service = Service(LoopbackTransport(), FakePool())
    port = free_port()
    server = build_server(service, "127.0.0.1", port)
    await server.start()
    try:
        answer = await asyncio.to_thread(post, port, "/api/v1/hook", {
            "session_id": SID, "cwd": "/tmp",
            "transcript_path": str(claude_home / "projects" / "-fake" / f"{SID}.jsonl"),
            "event": "Stop",
        })
        assert answer == {"ok": True, "agent": name, "event": "Stop", "events": 3,
                          "tools": 1, "phases_opened": 1, "phases_closed": 1}
        feed = await asyncio.to_thread(
            post, port, "/api/v1/agents/feed", {"agent": name, "since": 0, "wait": 0})
        assert [e["kind"] for e in feed["events"]] == ["phase", "tool", "outcome"]
        assert feed["events"][0]["text"] == "ship the release"
        assert feed["events"][0]["phase"] == feed["events"][1]["phase"]
    finally:
        await server.close()


async def test_the_safety_poll_catches_a_session_that_never_nudged(claude_home, doubles):
    """§2's safety net: a session that predates the install, or a nudge dropped
    while the daemon was restarting."""
    name = declared(doubles)
    write(claude_home, SID, [prompt("nobody nudged for this"), calls("Read", {"file_path": "/x"})])
    service = Service(LoopbackTransport(), FakePool())
    assert service.hook_events == 0

    swept = await service.poll_once()
    assert swept == {"sessions": 1, "events": 2}
    assert [p["title"] for p in service.store.phases(name)] == ["nobody nudged for this"]

    # The poll never closes a phase: only a Stop nudge knows a turn ended.
    assert service.store.phases(name)[0]["ended_at"] is None


async def test_the_poll_ignores_sessions_that_map_to_no_agent(claude_home, doubles):
    doubles["sessions"] = [Session("stranger")]
    doubles["records"] = []
    service = Service(LoopbackTransport(), FakePool())
    # A live session with no registry record still resolves, to the same derived
    # name the roster already lists it under -- that is not a phantom bucket.
    assert service.agent_for_session("stranger") == "stranger"
    assert service.agent_for_session("never-heard-of-it") is None


async def test_the_feed_wakes_when_the_hook_files_something(claude_home, doubles):
    name = declared(doubles)
    write(claude_home, SID, [prompt("go")])
    service = Service(LoopbackTransport(), FakePool())
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "UserPromptSubmit"})
    cursor = service.store.latest_seq()

    parked = asyncio.ensure_future(service.agent_feed(name, cursor, 5.0))
    await asyncio.sleep(0)
    assert not parked.done()

    write(claude_home, SID, [calls("Bash", {"command": "later"})])
    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "PreToolUse"})
    found = await asyncio.wait_for(parked, timeout=5)
    assert [e["tool"] for e in found["events"]] == ["Bash"]


# ---- context, from the statusline ----------------------------------------


async def test_a_context_sample_is_stored_and_a_null_one_is_not(claude_home, doubles):
    """§9.7: `used_percentage` is null before a session's first turn. Storing
    that as zero would draw a full gauge for a session whose usage is unknown."""
    name = declared(doubles)
    service = Service(LoopbackTransport(), FakePool())

    await service.hook({"session_id": SID, "cwd": "/tmp", "event": "StatusLine",
                        "context_used_percentage": None})
    assert service.store.agent(name) is None or service.store.agent(name)["context_used"] is None

    answer = await service.hook({"session_id": SID, "cwd": "/tmp", "event": "StatusLine",
                                 "context_used_percentage": 5})
    assert answer["events"] == 0, "a statusline report is not a reason to re-read the file"
    assert service.store.agent(name)["context_used"] == pytest.approx(0.05)


# ---- the store's own new surface -----------------------------------------


def test_a_database_written_before_these_columns_existed_still_opens(tmp_path):
    """`CREATE TABLE IF NOT EXISTS` does nothing to a table that already exists,
    and the database serving his phone already existed."""
    path = tmp_path / "old.db"
    import sqlite3

    old = sqlite3.connect(str(path))
    old.execute(
        "CREATE TABLE agents (name TEXT PRIMARY KEY, session_id TEXT, task TEXT, cwd TEXT,"
        " declared_at REAL, completed_at REAL, last_tool_at REAL, retired_at REAL,"
        " history_generation INTEGER NOT NULL DEFAULT 0,"
        " transcript_offset INTEGER NOT NULL DEFAULT 0, updated_at REAL)"
    )
    old.execute("INSERT INTO agents (name, transcript_offset) VALUES ('old-one', 512)")
    old.commit()
    old.close()

    store = Store(path)
    assert store.read_position("old-one") == (512, {})
    store.set_read_position("old-one", 900, {"agent-a.jsonl": 40})
    assert store.read_position("old-one") == (900, {"agent-a.jsonl": 40})
    store.close()


def test_phases_survive_a_restart(tmp_path):
    path = tmp_path / "phases.db"
    first = Store(path)
    first.open_phase("p1", "mapper", "do the thing", started_at=10.0)
    first.close_phase("p1", outcome="did the thing", ended_at=20.0)
    first.close()

    second = Store(path)
    row = second.phase("p1")
    assert (row["title"], row["outcome"], row["ended_at"]) == ("do the thing", "did the thing", 20.0)
    # Idempotent, and a second close does not null out the first outcome.
    assert second.close_phase("p1") is False
    assert second.phase("p1")["outcome"] == "did the thing"
    second.close()


def test_a_tool_summary_names_the_argument_that_identifies_the_call():
    assert ingest.summarise("Bash", {"command": "ls -la", "timeout": 5}) == "ls -la"
    assert ingest.summarise("Read", {"file_path": "/a/b.py", "limit": 20}) == "/a/b.py"
    assert ingest.summarise("Grep", {"pattern": "TODO", "path": "/src"}) == "TODO"
    assert ingest.summarise("Write", {"file_path": "/a", "content": "x" * 5000}) == "/a"
    long = ingest.summarise("Bash", {"command": "echo " + "x" * 500})
    assert len(long) == ingest.TOOL_SUMMARY_MAX
    assert long.endswith("…")
    # Newlines collapse: a row on a phone is one line.
    assert ingest.summarise("Bash", {"command": "a\n  b"}) == "a b"
    assert ingest.summarise("SomethingNew", {"whatever": "a value"}) == "a value"
    assert ingest.summarise("Nothing", {}) == ""


# ---- the hook script itself ----------------------------------------------


def test_the_installer_wraps_an_existing_statusline_rather_than_replacing_it(tmp_path,
                                                                            claude_home):
    """§9.7: `statusLine` is one slot per session. His terminal must look
    identical afterwards."""
    settings = tmp_path / "settings.json"
    settings.write_text(json.dumps({
        "statusLine": {"type": "command", "command": "/usr/local/bin/his-prompt"},
        "hooks": {"Stop": [{"matcher": "", "hooks": [
            {"type": "command", "command": "/home/bodas/.claude/hooks/hotline-stop.py"}]}]},
    }))
    result = hooks.install(settings_file=settings, scripts_dir=tmp_path / "h",
                           url="http://127.0.0.1:1/api/v1/hook")
    assert result["wrapped"] == "/usr/local/bin/his-prompt"

    written = json.loads(settings.read_text())
    assert written["statusLine"]["command"] == result["statusline"]
    assert "/usr/local/bin/his-prompt" in Path(result["statusline"]).read_text()
    # His own Stop hook is still there, beside ours, not replaced by it.
    stop = [h["command"] for entry in written["hooks"]["Stop"] for h in entry["hooks"]]
    assert "/home/bodas/.claude/hooks/hotline-stop.py" in stop
    assert result["hook"] in stop
    assert set(written["hooks"]) >= set(hooks.HOOK_EVENTS)

    # Idempotent, and a second install does not wrap the wrapper.
    again = hooks.install(settings_file=settings, scripts_dir=tmp_path / "h",
                          url="http://127.0.0.1:1/api/v1/hook")
    assert again["changed"] == []
    assert again["wrapped"] == "/usr/local/bin/his-prompt" or again["wrapped"] == ""
    assert json.loads(settings.read_text()) == written


def test_the_statusline_wrapper_passes_the_previous_output_through(tmp_path, claude_home):
    """Byte for byte, and the exit code with it."""
    inner = tmp_path / "inner.sh"
    inner.write_text("#!/bin/sh\ncat > /dev/null\nprintf 'HIS PROMPT'\nexit 3\n")
    inner.chmod(0o755)
    script = tmp_path / "sl.py"
    script.write_text(hooks.statusline_script(url="http://127.0.0.1:1/api/v1/hook",
                                              wrapped=str(inner)))
    done = subprocess.run(
        [sys.executable, str(script)],
        input=json.dumps({"session_id": "s", "context_window": {"used_percentage": None}}).encode(),
        capture_output=True, timeout=20, check=False,
    )
    assert done.stdout == b"HIS PROMPT"
    assert done.returncode == 3


def test_the_hook_gives_up_on_a_daemon_that_never_answers(tmp_path, claude_home):
    """§8's one legitimate bounded wait: the property under test IS boundedness.

    A socket that accepts and never answers is the shape a hung daemon takes,
    and it is the one that would otherwise hang every tool call on the box."""
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(5)
    port = listener.getsockname()[1]
    script = tmp_path / "hook.py"
    script.write_text(hooks.nudge_script(url=f"http://127.0.0.1:{port}/api/v1/hook"))
    payload = json.dumps({"session_id": "s", "cwd": "/tmp", "transcript_path": "/x",
                          "hook_event_name": "PreToolUse"}).encode()
    try:
        began = time.monotonic()
        done = subprocess.run([sys.executable, str(script)], input=payload,
                              capture_output=True, timeout=20, check=False)
        took = time.monotonic() - began
    finally:
        listener.close()
    assert done.returncode == 0
    assert took < 5.0, f"the hook blocked a tool call for {took:.1f}s"

    # And the failure leaves a backoff marker, so a dead daemon is paid for once
    # rather than on every tool call.
    marker = Path(tmp_path) / "run" / "ios-hook-backoff"
    assert marker.is_file()


def test_the_hook_exits_zero_when_nothing_is_listening(tmp_path, claude_home):
    script = tmp_path / "hook.py"
    script.write_text(hooks.nudge_script(url=f"http://127.0.0.1:{free_port()}/api/v1/hook"))
    done = subprocess.run([sys.executable, str(script)], input=b"not json at all",
                          capture_output=True, timeout=20, check=False)
    assert done.returncode == 0
    assert done.stdout == b""
