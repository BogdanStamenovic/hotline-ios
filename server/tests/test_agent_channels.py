"""Channels per agent: the roster's new fields, the feed, history, and deletion.

Every test here installs doubles for hotline's `Registry` and `ccsocks.discover`
rather than reading the box. Not only for determinism -- the real ones report
whatever Claude sessions happen to be running on archserver while the suite
runs, so a roster-invalidation test against them would tick on somebody else's
agent starting up and would be flaky in a way that looks like a bug in this
code.

Nothing here sleeps. Where something has to be waited for it is polled with a
bound, the `eventually()` pattern from `test_sip.py`.
"""

import asyncio
import json
import time
import urllib.error
import urllib.request

import pytest

pytest.importorskip(
    "hotline.httpd",
    reason="hotline not on sys.path -- run with PYTHONPATH=/home/bodas/data/hotline/src",
)

import hotline.agents
import hotline.ccsocks

from hotline_ios.daemon import STALL_AFTER, Service, build_server
from hotline_ios.ring.loopback import LoopbackTransport


class Reply:
    def __init__(self, text): self.text = text; self.notice = ""


class FakePool:
    def __init__(self): self.asked = []
    async def ask(self, key, text, narrator=None, timeout=None, origin=None):
        self.asked.append((key, text, origin))
        return ("fresh", Reply("nothing is on fire"))


class Record:
    """Enough of `hotline.agents.Agent` for the roster to read."""

    def __init__(self, name, session_id, task="", completed_at=None):
        self.name = name
        self.session_id = session_id
        self.task = task
        self.completed_at = completed_at
        self.declared_at = 1000.0


class Session:
    """Enough of `ccsocks.LiveSession` for the roster to read."""

    def __init__(self, session_id, name="", cwd="/tmp", status="idle"):
        self.session_id = session_id
        self.name = name or session_id[:8]
        self.cwd = cwd
        self.status = status


@pytest.fixture(autouse=True)
def doubles(monkeypatch):
    """An empty box by default; each test declares what is on it."""
    state = {"records": [], "sessions": []}

    class FakeRegistry:
        def __init__(self, *_a, **_k):
            self.agents = {r.session_id: r for r in state["records"]}

        def by_name(self, name):
            wanted = name.strip().lower()
            return next((r for r in state["records"] if r.name.lower() == wanted), None)

        def working(self):
            return [r for r in state["records"] if r.completed_at is None]

    monkeypatch.setattr(hotline.agents, "Registry", FakeRegistry)
    monkeypatch.setattr(hotline.ccsocks, "discover", lambda *_a, **_k: list(state["sessions"]))
    return state


async def eventually(predicate, *, within: float = 2.0) -> bool:
    """Poll a predicate to a deadline. The `test_sip.py` helper, same reasoning:
    a bare sleep either flakes or wastes the difference, and deleting the wait
    would delete the assertion."""
    deadline = asyncio.get_running_loop().time() + within
    while asyncio.get_running_loop().time() < deadline:
        if predicate():
            return True
        await asyncio.sleep(0.01)
    return predicate()


def post(port, path, payload, timeout=10):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def get(port, path, timeout=10):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
        return json.loads(r.read())


async def run_server(service, port):
    server = build_server(service, "127.0.0.1", port)
    await server.start()
    return server


def named(rows):
    return {row["name"]: row for row in rows}


# ---- the roster ---------------------------------------------------------


def test_the_five_fields_the_installed_app_decodes_are_still_there(doubles):
    """App-compat regression, not a shape test.

    The app on his phone is sideloaded on a free provisioning profile -- 7-day
    expiry, three devices, no self-service removal -- so a response that stops
    decoding costs a reinstall he cannot do from where he is. `Agent` in
    Model.swift declares exactly these five and every one is non-optional.
    """
    doubles["sessions"] = [Session("s1", name="data-88", cwd="/home/bodas/data", status="busy")]
    service = Service(LoopbackTransport(), FakePool())
    row = service.agents()["agents"][0]
    assert isinstance(row["name"], str)
    assert isinstance(row["task"], str)
    assert isinstance(row["cwd"], str)
    assert row["live"] is True
    assert row["busy"] is True


def test_a_clean_finish_and_a_crash_stop_looking_identical(doubles):
    """The unused second death signal. `completed_at` is set by `done` and only
    by `done`, so an agent that said it was finished is not the same event as
    one whose process is simply gone."""
    doubles["records"] = [
        Record("finished", "s1", task="built it", completed_at=2000.0),
        Record("crashed", "s2", task="was building it"),
    ]
    service = Service(LoopbackTransport(), FakePool())

    rows = named(service.agents(include_done=True)["agents"])
    assert rows["finished"]["state"] == "done"
    assert rows["crashed"]["state"] == "dead"
    assert rows["finished"]["deadReason"] != rows["crashed"]["deadReason"]
    assert rows["finished"]["deadReason"] and rows["crashed"]["deadReason"]

    # The default list is what it has always been: hotline's working agents.
    # Finished ones are extra ROWS, and quietly filling his list with corpses is
    # not covered by "the new fields are additive".
    assert set(named(service.agents()["agents"])) == {"crashed"}


def test_a_finished_agent_still_running_is_never_hidden(doubles):
    doubles["records"] = [Record("winding-down", "s1", completed_at=2000.0)]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    rows = named(service.agents()["agents"])
    assert rows["winding-down"]["state"] == "done"
    assert rows["winding-down"]["live"] is True


def test_state_follows_the_process_with_no_poll_in_between(doubles):
    """Liveness is a per-request check, so the flip needs no interval to elapse
    -- which is also why this test needs no clock."""
    doubles["records"] = [Record("hotline-80", "s1", task="building")]
    doubles["sessions"] = [Session("s1", status="busy")]
    service = Service(LoopbackTransport(), FakePool())
    assert named(service.agents()["agents"])["hotline-80"]["state"] == "working"

    doubles["sessions"] = [Session("s1", status="idle")]
    assert named(service.agents()["agents"])["hotline-80"]["state"] == "idle"

    doubles["sessions"] = []
    row = named(service.agents()["agents"])["hotline-80"]
    assert row["state"] == "dead"
    assert row["live"] is False


def test_stalled_is_never_claimed_without_having_observed_a_tool_call(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1", status="busy")]
    service = Service(LoopbackTransport(), FakePool())

    # Busy is the session's own word for itself and is exactly what goes stale
    # when a process hangs. Nothing has been observed, so nothing is claimed.
    assert named(service.agents()["agents"])["hotline-80"]["stalled"] is False

    service.store.set_last_tool_at("hotline-80", time.time())
    assert named(service.agents()["agents"])["hotline-80"]["stalled"] is False

    # Injected, not waited for -- the same trick the reap test uses.
    service.store.set_last_tool_at("hotline-80", time.time() - STALL_AFTER - 1)
    assert named(service.agents()["agents"])["hotline-80"]["stalled"] is True

    # And an agent that is not working cannot be stalled, however old the mark.
    doubles["sessions"] = []
    assert named(service.agents()["agents"])["hotline-80"]["stalled"] is False


async def test_the_blocked_pin_is_the_oldest_unanswered_question(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18830)
    try:
        assert named(service.agents()["agents"])["hotline-80"]["blocked"] is False

        first = await asyncio.to_thread(
            post, 18830, "/api/v1/call",
            {"reason": "may I spend money", "agent": "hotline-80", "wait": False})
        second = await asyncio.to_thread(
            post, 18830, "/api/v1/call",
            {"reason": "and on this too", "agent": "hotline-80", "wait": False})

        row = named(service.agents()["agents"])["hotline-80"]
        assert row["blocked"] is True
        opened = [service.store.conversation(c["conversation"])["opened_at"]
                  for c in (first, second)]
        assert row["blockedSince"] == min(opened)

        # Delegating work to him is not him being waited on.
        await asyncio.to_thread(
            post, 18830, "/api/v1/say", {"text": "carry on", "agent": "hotline-80"})
        assert named(service.agents()["agents"])["hotline-80"]["blockedSince"] == min(opened)

        # Answering the older one leaves him blocked on the newer, not free.
        await asyncio.to_thread(
            post, 18830, "/api/v1/reply",
            {"conversation": first["conversation"], "text": "yes"})
        row = named(service.agents()["agents"])["hotline-80"]
        assert row["blocked"] is True
        assert row["blockedSince"] == max(opened)

        await asyncio.to_thread(
            post, 18830, "/api/v1/reply",
            {"conversation": second["conversation"], "text": "yes"})
        assert named(service.agents()["agents"])["hotline-80"]["blocked"] is False
    finally:
        await server.close()


# ---- roster invalidation -------------------------------------------------


async def test_roster_events_report_a_change_and_then_block_until_the_next(doubles):
    """The stale-list fix. `.task` runs once per Store identity, so a
    foregrounded app shows whatever was true when it launched unless something
    tells it otherwise."""
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())

    # Baseline. The first computation of a process ticks nothing: a restart is
    # not the whole box changing at once.
    assert (await service.roster_events(0, 0))["events"] == []

    doubles["sessions"] = [Session("s1", status="busy")]
    page = await service.roster_events(0, 0)
    assert len(page["events"]) == 1
    assert page["events"][0]["agent"] == "hotline-80"
    assert "live" in page["events"][0]["text"]
    cursor = page["cursor"]

    # From that cursor there is nothing, so it parks.
    parked = asyncio.create_task(service.roster_events(cursor, 5))
    assert await eventually(lambda: not parked.done(), within=0.2) or not parked.done()
    await asyncio.sleep(0)
    assert not parked.done()

    # A real daemon action wakes it rather than the poll interval elapsing.
    service.retire("hotline-80", True)
    woken = await asyncio.wait_for(parked, timeout=3)
    assert woken["cursor"] > cursor
    # Two ticks, on purpose: `retire` emits one directly (an agent hotline's
    # registry has never heard of would otherwise never be ticked at all) and
    # the recompute that follows the wake diffs the same change. A tick is an
    # invalidation, not a fact, so a duplicate costs the client one refetch and
    # is not worth machinery to suppress.
    assert {e["agent"] for e in woken["events"]} == {"hotline-80"}
    assert any("retired" in e["text"] for e in woken["events"])


async def test_a_purge_reaches_the_phone_as_a_generation_change(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    service.store.append_event("hotline-80", "claude", "something", at=1.0)

    before = named(service.agents()["agents"])["hotline-80"]["historyGeneration"]
    service.purge("hotline-80")
    after = named(service.agents()["agents"])["hotline-80"]["historyGeneration"]
    # An unfamiliar generation is a client's instruction to throw its whole
    # local cache for this agent away and refetch.
    assert after == before + 1
    assert any("historyGeneration" in e.text for e in service.store.roster_since(0))


# ---- the agent-scoped feed ----------------------------------------------


async def test_one_channel_carries_a_ring_and_a_delegation_in_order(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18831)
    try:
        ring = await asyncio.to_thread(
            post, 18831, "/api/v1/call",
            {"reason": "may I spend money", "agent": "hotline-80", "wait": False})
        await asyncio.to_thread(
            post, 18831, "/api/v1/say", {"text": "status?", "agent": "hotline-80"})

        async def has_answer():
            page = await asyncio.to_thread(
                post, 18831, "/api/v1/agents/feed",
                {"agent": "hotline-80", "since": 0, "wait": 1}, 15)
            return page

        page = await has_answer()
        for _ in range(50):
            if any(e["kind"] == "claude" and e["text"] == "nothing is on fire"
                   for e in page["events"]):
                break
            page = await has_answer()

        seqs = [e["seq"] for e in page["events"]]
        assert seqs == sorted(seqs)
        assert len(set(seqs)) == len(seqs)
        # Two conversations, one channel: conversation stops being a display
        # concept and becomes a grouping key.
        conversations = {e["conversation"] for e in page["events"]}
        assert len(conversations) == 2
        assert ring["conversation"] in conversations
        assert page["closed"] is False
        assert all(e["agent"] == "hotline-80" for e in page["events"])
    finally:
        await server.close()


async def test_the_feed_parks_until_something_arrives(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    service.store.append_event("hotline-80", "claude", "first", at=1.0)
    cursor = service.store.latest_seq()

    parked = asyncio.create_task(service.agent_feed("hotline-80", cursor, 5))
    await asyncio.sleep(0)
    assert not parked.done()

    conversation, _ = service._open_conversation("hotline-80", "say")
    service._append(conversation, "you", "second")

    page = await asyncio.wait_for(parked, timeout=3)
    assert [e["text"] for e in page["events"]] == ["second"]
    assert page["cursor"] > cursor


async def test_a_dead_agents_channel_reads_as_closed(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())
    service.store.append_event("hotline-80", "claude", "last words", at=1.0)
    page = await service.agent_feed("hotline-80", 0, 0)
    assert page["closed"] is True
    assert [e["text"] for e in page["events"]] == ["last words"]


async def test_an_unknown_agent_is_a_404_not_an_empty_feed(doubles):
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18832)
    try:
        for path, payload in (
            ("/api/v1/agents/feed", {"agent": "nope", "since": 0, "wait": 0}),
            ("/api/v1/agents/history", {"agent": "nope"}),
            ("/api/v1/agents/retire", {"agent": "nope", "retired": True}),
        ):
            with pytest.raises(urllib.error.HTTPError) as exc:
                await asyncio.to_thread(post, 18832, path, payload)
            assert exc.value.code == 404, path
    finally:
        await server.close()


# ---- history -------------------------------------------------------------


async def test_history_pages_backwards_and_meets_the_feed_over_http(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    doubles["sessions"] = [Session("s1")]
    service = Service(LoopbackTransport(), FakePool())
    for i in range(25):
        service.store.append_event("hotline-80", "tool", f"e{i}", at=float(i))
    server = await run_server(service, 18833)
    try:
        page = await asyncio.to_thread(
            post, 18833, "/api/v1/agents/history", {"agent": "hotline-80", "limit": 10})
        assert page["has_more"] is True
        assert len(page["events"]) == 10
        assert page["oldest_seq"] == page["events"][0]["seq"]
        assert page["newest_seq"] == page["events"][-1]["seq"]

        older = await asyncio.to_thread(
            post, 18833, "/api/v1/agents/history",
            {"agent": "hotline-80", "before": page["oldest_seq"], "limit": 10})
        assert older["newest_seq"] < page["oldest_seq"]

        ahead = await asyncio.to_thread(
            post, 18833, "/api/v1/agents/feed",
            {"agent": "hotline-80", "since": page["newest_seq"], "wait": 0})
        assert ahead["events"] == []
    finally:
        await server.close()


async def test_history_refuses_to_hand_a_phone_the_whole_database(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())
    for i in range(250):
        service.store.append_event("hotline-80", "tool", f"e{i}", at=float(i))
    page = service.history("hotline-80", None, 10_000)
    assert len(page["events"]) == 200


# ---- retention -----------------------------------------------------------


async def test_a_dry_run_shows_him_real_numbers_and_deletes_nothing(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18834)
    try:
        ring = await asyncio.to_thread(
            post, 18834, "/api/v1/call",
            {"reason": "ping", "agent": "hotline-80", "wait": False})
        held = len(service.store.since("hotline-80", 0))

        preview = await asyncio.to_thread(
            post, 18834, "/api/v1/agents/purge",
            {"agent": "hotline-80", "scope": "history", "dry_run": True})
        # "hotline-80 -- 340 events since Aug 12", not a generic warning.
        assert preview["events"] == held
        assert preview["conversations"] == 1
        assert preview["oldest_at"] is not None
        assert len(service.store.since("hotline-80", 0)) == held

        done = await asyncio.to_thread(
            post, 18834, "/api/v1/agents/purge", {"agent": "hotline-80", "scope": "history"})
        assert done["events"] == held
        assert service.store.since("hotline-80", 0) == []
        assert done["history_generation"] == preview["history_generation"] + 1
        # The index drops what no longer exists rather than serving a ghost.
        assert ring["conversation"] not in service.calls
    finally:
        await server.close()


async def test_purging_everything_is_refused_rather_than_downgraded(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())
    service.store.open_conversation("c1", "hotline-80", "ring", opened_at=1.0)
    service.store.append_event("hotline-80", "tool", "e", conversation_id="c1", at=1.0)
    server = await run_server(service, 18835)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(
                post, 18835, "/api/v1/agents/purge",
                {"agent": "hotline-80", "scope": "everything", "conversation_id": "c1"})
        assert exc.value.code == 400
        # Refused, not half-done.
        assert len(service.store.since("hotline-80", 0)) == 1
    finally:
        await server.close()


async def test_retire_hides_an_agent_and_gives_it_back(doubles):
    doubles["records"] = [Record("hotline-80", "s1"), Record("data-88", "s2")]
    doubles["sessions"] = [Session("s1"), Session("s2")]
    service = Service(LoopbackTransport(), FakePool())
    service.store.append_event("hotline-80", "claude", "kept", at=1.0)
    server = await run_server(service, 18836)
    try:
        out = await asyncio.to_thread(
            post, 18836, "/api/v1/agents/retire", {"agent": "hotline-80", "retired": True})
        assert out["retired"] is True

        listing = await asyncio.to_thread(post, 18836, "/api/v1/agents", {})
        assert set(named(listing["agents"])) == {"data-88"}
        # An agent can be live and retired at once: it is him not wanting to
        # look at it, not it being finished.
        listing = await asyncio.to_thread(
            post, 18836, "/api/v1/agents", {"include_retired": True})
        assert named(listing["agents"])["hotline-80"]["live"] is True
        assert named(listing["agents"])["hotline-80"]["retired"] is True

        # Nothing was destroyed.
        assert [e.text for e in service.store.since("hotline-80", 0)] == ["kept"]

        back = await asyncio.to_thread(
            post, 18836, "/api/v1/agents/retire", {"agent": "hotline-80", "retired": False})
        assert back["retired"] is False
        listing = await asyncio.to_thread(post, 18836, "/api/v1/agents", {})
        assert set(named(listing["agents"])) == {"hotline-80", "data-88"}
    finally:
        await server.close()


async def test_retire_will_not_guess_which_way_he_meant(doubles):
    doubles["records"] = [Record("hotline-80", "s1")]
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18837)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(
                post, 18837, "/api/v1/agents/retire", {"agent": "hotline-80"})
        assert exc.value.code == 400
    finally:
        await server.close()


# ---- /health -------------------------------------------------------------


async def test_health_reports_the_database_it_actually_checked(doubles):
    service = Service(LoopbackTransport(), FakePool())
    server = await run_server(service, 18838)
    try:
        body = await asyncio.to_thread(get, 18838, "/health")
        assert body["db_ok"] is True
        assert body["db_bytes"] > 0
        assert body["disk_free"] > 0
        # The existing contract is untouched: ok still means the doorbell, and
        # this doorbell is a loopback that rings nothing.
        assert body["ok"] is False

        # A store that has stopped working must read as not-ok here and say so
        # where it is actually read, rather than reporting a boot-time success.
        service.store.close()
        broken = await asyncio.to_thread(get, 18838, "/health")
        assert broken["db_ok"] is False
        assert any("store not readable" in d for d in broken["degradations"])
    finally:
        await server.close()
