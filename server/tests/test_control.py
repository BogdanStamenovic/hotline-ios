"""Control and telemetry: what he can do to an agent, and what it is doing.

**Nothing here touches a real session.** Every destructive path -- interrupt,
kill, retask, spawn -- is a fake that records what it was asked to do, and the
assertion is that the daemon asked for the right thing with the right argument.
That is not squeamishness: this box has live agent sessions on it and one of
them is running this suite. A test that proved `stop` works by stopping
something would be a test that occasionally stops the wrong thing.

The observational half is different and is verified against a real session
elsewhere; what is pinned here is the projection, against known inputs.

Nothing sleeps. Where something has to be waited for it is polled with a bound.
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
import hotline.revive
import hotline.tmuxen
from hotline.errors import HotlineError

from hotline_ios import vitals
from hotline_ios.daemon import STOP_DEBOUNCE, Service, build_server
from hotline_ios.ring.loopback import LoopbackTransport


class Reply:
    def __init__(self, text): self.text = text; self.notice = ""


class FakePool:
    def __init__(self): self.asked = []
    async def ask(self, key, text, narrator=None, timeout=None, origin=None):
        self.asked.append((key, text, origin))
        return ("fresh", Reply("nothing is on fire"))


class Record:
    """Enough of `hotline.agents.Agent` for the roster and the controls."""

    def __init__(self, name, session_id, task="", completed_at=None, handoff=None):
        self.name = name
        self.session_id = session_id
        self.task = task
        self.completed_at = completed_at
        self.handoff = handoff
        self.declared_at = 1000.0
        self.channel_id = None


class Session:
    """Enough of `ccsocks.LiveSession`. `tmux` is the field the pty gate reads."""

    def __init__(self, session_id, name="", cwd="/tmp", status="idle",
                 tmux=None, pid=4242):
        self.session_id = session_id
        self.name = name or session_id[:8]
        self.cwd = cwd
        self.status = status
        self.tmux = tmux
        self.pid = pid


class Box:
    """Everything the daemon reaches out to, recorded rather than performed."""

    def __init__(self):
        self.records = []
        self.sessions = []
        self.panes = set()
        self.calls = []
        self.status = {}
        self.interrupt_fails = ""
        self.inject_fails = ""
        self.compaction = None

    def declare(self, name, session_id, **kw):
        record = Record(name, session_id, **kw)
        self.records.append(record)
        return record

    def live(self, session_id, **kw):
        session = Session(session_id, **kw)
        self.sessions.append(session)
        if session.tmux:
            self.panes.add(session.tmux.split(":", 1)[0])
        return session


@pytest.fixture
def box(monkeypatch):
    state = Box()

    class FakeRegistry:
        def __init__(self, *_a, **_k):
            self.agents = {r.session_id: r for r in state.records}

        def by_name(self, name):
            wanted = name.strip().lower()
            return next((r for r in state.records if r.name.lower() == wanted), None)

        def working(self):
            return [r for r in state.records if r.completed_at is None]

        def declare(self, session_id, name, task, **_k):
            state.calls.append(("declare", name, session_id, task))
            return state.declare(name, session_id, task=task)

    async def interrupt(target):
        state.calls.append(("interrupt", target))
        if state.interrupt_fails:
            raise HotlineError(state.interrupt_fails)

    async def send_command(target, command, settle=0.0):
        state.calls.append(("send_command", target, command))

    async def inject(session, text, timeout=5.0):
        state.calls.append(("inject", session.session_id, text))
        if state.inject_fails:
            raise HotlineError(state.inject_fails)

    async def terminate(session, grace=8.0):
        state.calls.append(("terminate", session.session_id, session.pid))
        return "stopped"

    monkeypatch.setattr(hotline.agents, "Registry", FakeRegistry)
    monkeypatch.setattr(hotline.ccsocks, "discover", lambda *_a, **_k: list(state.sessions))
    monkeypatch.setattr(hotline.ccsocks, "inject", inject)
    monkeypatch.setattr(hotline.ccsocks, "terminate", terminate)
    monkeypatch.setattr(hotline.ccsocks, "status_of", lambda pid: state.status.get(pid))
    monkeypatch.setattr(hotline.tmuxen, "interrupt", interrupt)
    monkeypatch.setattr(hotline.tmuxen, "send_command", send_command)
    monkeypatch.setattr(hotline.tmuxen, "sessions", lambda: set(state.panes))
    monkeypatch.setattr(hotline.tmuxen, "exists", lambda name: name in state.panes)
    return state


def service_for(box):
    return Service(LoopbackTransport(), FakePool())


def controls(service, agent):
    row = next(r for r in service.agents()["agents"] if r["name"] == agent)
    return {c["id"]: c for c in row["controls"]}


async def eventually(predicate, *, within: float = 2.0) -> bool:
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


# ---- the capability declaration -------------------------------------------


def test_every_capability_carries_a_label_a_state_and_a_reason_when_off(box):
    """The app renders this array and hardcodes none of it -- not which
    capabilities exist, not their order, not their labels, not `enabled`. A
    reinstall costs him a week of provisioning, so anything the UI can show has
    to be answerable by the daemon at runtime."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1")
    found = controls(service_for(box), "hotline-80")

    assert set(found) == {"stop", "compact", "retask", "resume", "kill"}
    for capability in found.values():
        assert capability["label"] and isinstance(capability["label"], str)
        assert isinstance(capability["enabled"], bool)
        # A disabled control with no reason is indistinguishable on the phone
        # from a broken one, and a reason on a working control is noise.
        assert (capability["reason"] is None) == capability["enabled"]


def test_stop_and_compact_need_a_pty_and_say_so_when_there_is_none(box):
    """The cancel is a keystroke, so it needs a terminal. A headless `claude -p`
    has none and can only be killed -- which is a different act with a different
    consequence, and the reason has to say which."""
    box.declare("headless", "s1")
    box.live("s1", tmux=None, status="busy")
    found = controls(service_for(box), "headless")

    assert found["stop"]["enabled"] is False
    assert found["compact"]["enabled"] is False
    assert "headless" in found["stop"]["reason"]
    assert "only killed" in found["stop"]["reason"]
    # Killing it is still perfectly possible, which is the asymmetry the copy
    # has to make explicit rather than implying two strengths of one thing.
    assert found["kill"]["enabled"] is True


def test_a_dead_agent_offers_resume_and_nothing_that_needs_a_process(box, monkeypatch):
    monkeypatch.setattr(hotline.revive, "brief_for", lambda agent: object())
    box.declare("gone", "s1")
    found = controls(service_for(box), "gone")

    assert found["resume"]["enabled"] is True
    for off in ("stop", "compact", "retask", "kill"):
        assert found[off]["enabled"] is False
        assert found[off]["reason"] == "not running" or "gone" in found[off]["reason"]


def test_resume_is_refused_when_nothing_survives_to_resume_from(box, monkeypatch):
    """Offering a revive that cannot happen is worse than a shorter list."""
    monkeypatch.setattr(hotline.revive, "brief_for", lambda agent: None)
    box.declare("ghost", "s1")
    found = controls(service_for(box), "ghost")

    assert found["resume"]["enabled"] is False
    assert "no handoff" in found["resume"]["reason"]


def test_a_pane_dying_under_a_live_process_turns_stop_off(box):
    """`enabled` is computed per agent at request time and never cached. This is
    the case that proves it: the process is alive the whole way through and only
    the pane goes."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)
    assert controls(service, "hotline-80")["stop"]["enabled"] is True

    box.panes.clear()
    again = controls(service, "hotline-80")
    assert again["stop"]["enabled"] is False
    assert "hl-80 is gone" in again["stop"]["reason"]
    assert again["kill"]["enabled"] is True, "the process is still there to kill"


def test_a_pane_dying_wakes_the_roster_even_though_nothing_else_changed(box):
    """`live`, `busy` and `state` are all unmoved, so without this the phone
    would keep showing two buttons that now 409."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)
    service.agents()
    before = service.store.latest_roster_seq()

    box.panes.clear()
    service.agents()
    ticks = service.store.roster_since(before)

    assert [t.agent_name for t in ticks] == ["hotline-80"]
    assert "controls" in ticks[0].text


def test_the_box_declares_whether_a_new_agent_can_be_started(box, monkeypatch):
    """`new` belongs to the machine, not to any agent, so it rides on /health.
    Verified rather than assumed: a box with no tmux cannot spawn one."""
    monkeypatch.setattr("shutil.which", lambda name: None)
    service = service_for(box)
    declared = service.global_controls()

    assert [c["id"] for c in declared] == ["new"]
    assert declared[0]["enabled"] is False
    assert "tmux is not installed" in declared[0]["reason"]


# ---- stop ------------------------------------------------------------------


async def test_stop_asks_for_a_cancel_by_name_and_hands_it_the_pane(box):
    """The daemon knows nothing about tmux or ptys. It names the operation and
    `tmuxen.interrupt` owns how it is performed, so a socket-level cancel later
    is a one-function swap rather than an audit of every endpoint."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)

    assert await service.stop("hotline-80") == {"agent": "hotline-80", "interrupted": True}
    assert box.calls == [("interrupt", "hl-80:@1.%1")]


async def test_stop_is_refused_by_the_server_even_when_a_stale_client_offers_it(box):
    """Server-side enforcement is independent of the declaration. His phone
    holds a roster that can be minutes old; the refusal is re-derived when the
    request arrives, not read back off what was sent."""
    from hotline.httpd import HttpError

    box.declare("headless", "s1")
    box.live("s1", tmux=None, status="busy")
    service = service_for(box)

    # A hand-built stale roster claiming it is available, exactly as a phone
    # that has been asleep would be holding.
    stale = service._controls("headless", box.sessions[0], live=True, panes={"hl-80"})
    assert {c["id"]: c["enabled"] for c in stale}["stop"] is False

    with pytest.raises(HttpError) as raised:
        await service.stop("headless")
    assert raised.value.status == 409
    assert "headless" in raised.value.message
    assert box.calls == [], "nothing may be typed at a session with no pane"


async def test_two_rapid_stops_interrupt_once_and_the_second_is_told_so(box):
    """Sub-200 ms double-Escape behaviour is unverified and this avoids
    designing around a guess. It also makes a client retry-on-timeout safe: the
    second request is told the first landed rather than firing again."""
    from hotline.httpd import HttpError

    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)

    await service.stop("hotline-80")
    with pytest.raises(HttpError) as raised:
        await service.stop("hotline-80")

    assert raised.value.status == 409
    assert raised.value.message == "already interrupting"
    assert [c for c in box.calls if c[0] == "interrupt"] == [("interrupt", "hl-80:@1.%1")]


async def test_the_debounce_expires_rather_than_latching(box, monkeypatch):
    """Injected, never slept: `STOP_DEBOUNCE` is two seconds and waiting it out
    would put two seconds into the suite to assert one comparison."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)

    await service.stop("hotline-80")
    service._last_stop_at["hotline-80"] -= STOP_DEBOUNCE + 1
    await service.stop("hotline-80")

    assert len([c for c in box.calls if c[0] == "interrupt"]) == 2


async def test_a_cancel_that_did_not_land_does_not_block_the_retry(box):
    """The debounce exists to stop a second Escape reaching a session that
    already got one. A session that got none must stay retryable."""
    from hotline.httpd import HttpError

    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    box.interrupt_fails = "no such pane"
    service = service_for(box)

    for _ in range(2):
        with pytest.raises(HttpError):
            await service.stop("hotline-80")
    assert len([c for c in box.calls if c[0] == "interrupt"]) == 2


async def test_stop_is_filed_in_the_agents_own_channel(box):
    """A cancel is a fact about the session, not a toast about a button press,
    so it belongs in the record he scrolls."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)

    await service.stop("hotline-80")
    texts = [e.text for e in service.store.since("hotline-80", 0)]
    assert any("interrupted from the phone" in t for t in texts)
    assert any("still running" in t for t in texts), "the asymmetry with kill, in words"


# ---- kill ------------------------------------------------------------------


async def test_kill_terminates_the_exact_session_it_resolved(box):
    """`ccsocks.terminate` on the session already resolved, rather than handing
    a name back to the router's fuzzy resolver so it can find it again. That
    second lookup is a chance to find a different session, on the one endpoint
    where it would be unrecoverable."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", pid=777)
    service = service_for(box)

    assert await service.kill("hotline-80") == {"agent": "hotline-80", "outcome": "stopped"}
    assert box.calls == [("terminate", "s1", 777)]


async def test_kill_is_refused_for_something_that_is_not_running(box):
    from hotline.httpd import HttpError

    box.declare("gone", "s1")
    service = service_for(box)
    with pytest.raises(HttpError) as raised:
        await service.kill("gone")
    assert raised.value.status == 409
    assert raised.value.message == "not running"
    assert box.calls == []


# ---- retask ----------------------------------------------------------------


async def test_retask_with_stop_first_interrupts_then_injects_in_that_order(box):
    """One request rather than two, because if the interrupt lands and the
    network drops the second call the agent is cancelled with nothing queued to
    replace it."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy")
    service = service_for(box)

    out = await service.retask("hotline-80", "do the other thing", stop_first=True)

    assert [c[0] for c in box.calls] == ["interrupt", "inject"]
    assert box.calls[1] == ("inject", "s1", "do the other thing")
    assert out["interrupted"] is True and out["delivered"] is True


async def test_stop_first_is_refused_not_silently_downgraded(box):
    """"it stopped and started the new work" and "it will get to this after the
    current turn" are different outcomes and he acts on them differently."""
    from hotline.httpd import HttpError

    box.declare("headless", "s1")
    box.live("s1", tmux=None, status="busy")
    service = service_for(box)

    with pytest.raises(HttpError) as raised:
        await service.retask("headless", "do the other thing", stop_first=True)

    assert raised.value.status == 409
    assert "stop_first was asked for" in raised.value.message
    assert box.calls == [], "nothing may be delivered when the request was refused"


async def test_retask_reports_queued_from_the_sessions_own_status(box):
    """Observed after the fact rather than predicted. Whether this lands now or
    waits its turn is a fact about the session at that instant, and the
    descriptor is the session's own word for it."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy", pid=99)
    service = service_for(box)

    box.status[99] = "busy"
    assert (await service.retask("hotline-80", "later"))["queued"] is True
    box.status[99] = "idle"
    assert (await service.retask("hotline-80", "now"))["queued"] is False


async def test_retask_echoes_the_client_token_and_carries_it_on_the_row(box):
    """Turns reconciling a local echo against the feed from "sound because this
    phone is the only writer" into an equality test."""
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1")
    service = service_for(box)

    out = await service.retask("hotline-80", "hello", client_token="abc-123")

    assert out["client_token"] == "abc-123"
    rows = [e for e in service.store.since("hotline-80", 0) if e.kind == "you"]
    assert [r.client_token for r in rows] == ["abc-123"]
    assert rows[0].as_json()["client_token"] == "abc-123"


# ---- resume and new --------------------------------------------------------


async def test_resume_goes_through_the_one_shared_revive(box, monkeypatch):
    """Not a second implementation. `--resume` and this call the same function,
    so the two cannot drift on what resuming means."""
    asked = {}

    class Brief:
        seed = "here is what survived"
        from_handoff = True

    class Resumed:
        agent = Record("data-f3", "s2", task="mirror")
        session = Session("s2", name="data-f3", tmux="hl-data-f3:@1.%1")
        brief = Brief()
        tmux = "hl-data-f3"
        kept_channel = True
        channel_error = None
        from_handoff = True

    async def fake_resume(name, registry, *, cwd=None, channels=None):
        asked.update(name=name, cwd=cwd)
        return Resumed()

    monkeypatch.setattr(hotline.revive, "resume", fake_resume)
    service = service_for(box)

    out = await service.resume("data-f3", cwd="/home/bodas/data")

    assert asked == {"name": "data-f3", "cwd": "/home/bodas/data"}
    assert out["agent"] == "data-f3" and out["session"] == "s2"
    assert out["from_handoff"] is True and out["seeded"] is True
    # The brief is injected and not waited on: the CLI waits five minutes for
    # the first answer and prints it, and an HTTP request from a phone cannot.
    assert box.calls == [("inject", "s2", "here is what survived")]


async def test_resume_reports_a_brief_it_could_not_deliver(box, monkeypatch):
    class Resumed:
        agent = Record("data-f3", "s2")
        session = Session("s2")
        brief = type("B", (), {"seed": "x", "from_handoff": False})()
        tmux = "hl-data-f3"
        kept_channel = False
        channel_error = None
        from_handoff = False

    monkeypatch.setattr(
        hotline.revive, "resume",
        lambda name, registry, **_k: asyncio.sleep(0, result=Resumed()),
    )
    box.inject_fails = "socket refused"
    service = service_for(box)

    out = await service.resume("data-f3")
    assert out["seeded"] is False, "a session that never got its brief is not a clean resume"


async def test_resume_turns_its_two_refusals_into_different_statuses(box, monkeypatch):
    from hotline.httpd import HttpError

    async def missing(name, registry, **_k):
        raise hotline.revive.NoSuchAgent("no agent called 'nobody'")

    async def empty(name, registry, **_k):
        raise hotline.revive.NothingToResumeFrom("it left nothing")

    service = service_for(box)
    monkeypatch.setattr(hotline.revive, "resume", missing)
    with pytest.raises(HttpError) as gone:
        await service.resume("nobody")
    monkeypatch.setattr(hotline.revive, "resume", empty)
    with pytest.raises(HttpError) as nothing:
        await service.resume("ghost")

    assert gone.value.status == 404, "a name that does not exist is not a conflict"
    assert nothing.value.status == 409


async def test_new_spawns_declares_and_hands_over_the_task(box, monkeypatch):
    spawned = {}

    async def spawn(key, cwd=None, bypass=True, timeout=90.0, name=None):
        spawned.update(key=key, cwd=cwd, name=name, timeout=timeout)
        return Session("s9", name="data-99", tmux="hl-worker:@1.%1")

    monkeypatch.setattr(hotline.tmuxen, "spawn", spawn)
    monkeypatch.setattr("shutil.which", lambda name: "/usr/bin/" + name)
    service = service_for(box)

    out = await service.new_agent("mirror the ollama server", cwd="/tmp", name="worker")

    assert spawned["name"] == "worker" and spawned["cwd"] == "/tmp"
    assert out == {"agent": "worker", "session": "s9", "delivered": True,
                   "tmux": "hl-worker:@1.%1"}
    assert ("declare", "worker", "s9", "mirror the ollama server") in box.calls
    assert ("inject", "s9", "mirror the ollama server") in box.calls


async def test_new_refuses_rather_than_spawning_on_a_box_that_cannot(box, monkeypatch):
    from hotline.httpd import HttpError

    monkeypatch.setattr("shutil.which", lambda name: None)
    monkeypatch.setattr(
        hotline.tmuxen, "spawn",
        lambda *a, **k: pytest.fail("nothing may be spawned when the box cannot"),
    )
    service = service_for(box)

    with pytest.raises(HttpError) as raised:
        await service.new_agent("do a thing")
    assert raised.value.status == 409


# ---- compact ---------------------------------------------------------------


class FakeIngested:
    def __init__(self, compaction=None):
        self.events = 0
        self.tools = 0
        self.phases_opened = 0
        self.phases_closed = 0
        self.last_tool_at = None
        self.last_compaction = compaction or {}


def compaction_after(service, reads, detail):
    """Make the Nth transcript read be the one that finds the boundary.

    Standing in for the file, not for the wait: the endpoint still has to
    observe a marker rather than assume one after a delay.
    """
    seen = {"n": 0}

    async def ingest_session(agent, session_id, *, turn_ended=False):
        seen["n"] += 1
        return FakeIngested(detail if seen["n"] >= reads else None)

    service.ingest_session = ingest_session
    return seen


async def test_compact_interrupts_types_the_command_and_then_injects(box, monkeypatch):
    """The two steps use two different channels on purpose. `/compact` over the
    socket arrives as literal text the model cannot act on -- observed, not
    supposed -- and only the pty runs it. The continuation is the opposite:
    it genuinely is a user message, so `inject` is right for it."""
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_SETTLE", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_POLL", 0)
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", status="busy", pid=5)
    service = service_for(box)
    compaction_after(service, 2, {
        "trigger": "manual", "pre_tokens": 48027, "post_tokens": 4070,
        "dropped_tokens": 43957, "duration_ms": 71104,
    })

    out = await service.compact("hotline-80")

    assert [c[0] for c in box.calls] == ["interrupt", "send_command", "inject"]
    assert box.calls[1] == ("send_command", "hl-80:@1.%1", "/compact")
    assert out["interrupted"] is True and out["compacted"] is True and out["resumed"] is True
    # The CLI's own figures, not a timer and not an estimate. This is what lets
    # the button say "48k -> 4.1k in 71s" instead of showing a green tick.
    assert out["preTokens"] == 48027
    assert out["postTokens"] == 4070
    assert out["durationMs"] == 71104


async def test_compact_sends_the_continuation_it_was_given(box, monkeypatch):
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_SETTLE", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_POLL", 0)
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", pid=5)
    service = service_for(box)
    compaction_after(service, 1, {"pre_tokens": 10, "post_tokens": 2, "duration_ms": 5})

    await service.compact("hotline-80", then="carry on with the migration")
    assert ("inject", "s1", "carry on with the migration") in box.calls


async def test_a_session_that_goes_idle_without_a_boundary_is_not_a_compaction(
    box, monkeypatch
):
    """The descriptor flipping to idle is a reason to stop waiting, not a
    success: a session that never ran the command is also idle, and calling that
    compacted is the green-check-that-measures-nothing this project has been
    burned by."""
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_SETTLE", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_POLL", 0)
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", pid=5)
    service = service_for(box)

    order = ["busy", "idle", "idle", "idle"]

    def status_of(pid):
        return order.pop(0) if order else "idle"

    monkeypatch.setattr(hotline.ccsocks, "status_of", status_of)

    async def never(agent, session_id, *, turn_ended=False):
        return FakeIngested(None)

    service.ingest_session = never

    out = await service.compact("hotline-80")

    assert out["compacted"] is False and out["resumed"] is False
    assert out["preTokens"] is None
    assert "did not run" in out["detail"]
    # Nothing is fired into a session whose state is unknown.
    assert [c[0] for c in box.calls] == ["interrupt", "send_command"]


async def test_a_compaction_that_could_not_be_resumed_says_so(box, monkeypatch):
    """`resumed: false` is a valid, honest outcome. The app renders it with a
    Continue button rather than as an error or as a success."""
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_SETTLE", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_POLL", 0)
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", pid=5)
    box.inject_fails = "socket refused"
    service = service_for(box)
    compaction_after(service, 1, {"pre_tokens": 100, "post_tokens": 10, "duration_ms": 900})

    out = await service.compact("hotline-80")

    assert out["compacted"] is True and out["resumed"] is False
    assert out["preTokens"] == 100
    assert "continuation could not be delivered" in out["detail"]


async def test_compact_gives_up_on_a_bound_and_reports_it_rather_than_resuming(
    box, monkeypatch
):
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_SETTLE", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_POLL", 0)
    monkeypatch.setattr("hotline_ios.daemon.COMPACT_TIMEOUT", 0.05)
    box.declare("hotline-80", "s1")
    box.live("s1", tmux="hl-80:@1.%1", pid=5)
    service = service_for(box)

    async def never(agent, session_id, *, turn_ended=False):
        return FakeIngested(None)

    service.ingest_session = never
    out = await service.compact("hotline-80")

    assert out["compacted"] is False and out["resumed"] is False
    assert "no compaction boundary appeared" in out["detail"]
    assert not [c for c in box.calls if c[0] == "inject"]


async def test_compact_is_refused_for_a_session_with_no_pane(box):
    from hotline.httpd import HttpError

    box.declare("headless", "s1")
    box.live("s1", tmux=None, status="busy")
    service = service_for(box)

    with pytest.raises(HttpError) as raised:
        await service.compact("headless")
    assert raised.value.status == 409
    assert box.calls == []


# ---- telemetry -------------------------------------------------------------


def test_tools_per_minute_is_counted_not_estimated(box):
    box.declare("hotline-80", "s1")
    box.live("s1", status="busy", tmux="hl-80:@1.%1")
    service = service_for(box)
    now = time.time()
    for i in range(6):
        service.store.append_event("hotline-80", "tool", "ls", tool="Bash", at=now - i)
    # Outside the window, so it must not be counted.
    service.store.append_event("hotline-80", "tool", "old", tool="Bash",
                               at=now - vitals.WINDOW - 10)

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["toolsPerMin"] == round(6 * 60.0 / vitals.WINDOW, 2)


def test_a_dead_agent_is_flat_and_still(box):
    """A correctness requirement on the data, not a styling note: the app
    short-circuits every animation on a dead row, and the numbers behind it have
    to agree rather than idling."""
    box.declare("gone", "s1")
    service = service_for(box)
    service.rates.observe("gone", [(time.time() - vitals.WINDOW - 5, 4000)])

    row = next(r for r in service.agents(include_done=True)["agents"] if r["name"] == "gone")
    assert row["vitals"]["tokensPerSec"] == 0.0
    assert row["vitals"]["toolsPerMin"] == 0.0
    assert row["vitals"]["lastToolAt"] is None


def test_the_output_rate_is_characters_over_the_time_they_were_observed_in(box):
    box.declare("hotline-80", "s1")
    box.live("s1", status="busy")
    service = service_for(box)
    now = time.time()
    service.rates.observe("hotline-80", [(now - 20, 600), (now - 10, 400)])

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["tokensPerSec"] == pytest.approx(1000 / 20, rel=0.05)


def test_a_burst_is_not_divided_by_the_whole_window(box):
    """Without a floor on the denominator the first sample of a burst divides by
    nearly zero and prints a rate in the thousands; without any span at all it
    divides by ninety and prints an agent hard at work as almost idle."""
    rates = vitals.Rates()
    now = time.time()
    rates.observe("a", [(now - 1, 500)])
    assert rates.chars_per_sec("a", now) == pytest.approx(500 / vitals.MIN_SPAN)


def test_time_blocked_is_the_real_wait_and_is_absent_when_there_is_none(box):
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["blockedFor"] is None, "not waiting is not waiting for zero seconds"

    service.store.open_conversation("c1", "hotline-80", "ring",
                                    opened_at=time.time() - 300,
                                    waiting_since=time.time() - 300)
    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["blockedFor"] == pytest.approx(300, abs=2)


def test_context_used_is_absent_until_the_cli_reports_one(box):
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["contextUsed"] is None

    service.store.set_context_used("hotline-80", 0.32)
    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["vitals"]["contextUsed"] == 0.32


async def test_no_first_turn_yet_and_no_wrapper_installed_stop_looking_alike(box):
    """Both arrive as a missing number and they mean opposite things: one fills
    in within thirty seconds and the other never will. This is the whole reason
    the boolean exists separately from the value."""
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["contextAvailable"] is False
    assert row["vitals"]["contextUsed"] is None

    # A statusLine report carrying no usage figure at all -- which is what the
    # CLI sends before a session's first turn. It still proves the wrapper is
    # there, which is the fact this field reports.
    await service.hook({"session_id": "s1", "event": "StatusLine"})

    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["contextAvailable"] is True
    assert row["vitals"]["contextUsed"] is None, "still no first turn"


def test_the_roster_carries_when_the_agent_declared_itself(box):
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)
    row = next(r for r in service.agents()["agents"] if r["name"] == "hotline-80")
    assert row["declaredAt"] == 1000.0


async def test_a_tool_duration_reaches_the_row_it_belongs_to(box):
    """The only place a per-tool duration exists. The transcript's `durationMs`
    records are whole turns and there is nothing per-call in the file -- checked
    against a real one, not assumed."""
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)
    service.store.append_event("hotline-80", "tool", "ls -la", tool="Bash",
                               tool_use_id="toolu_01")

    answer = await service.hook({
        "session_id": "s1", "event": "PostToolUse",
        "tool_use_id": "toolu_01", "duration_ms": 1234,
    })

    assert answer["timed"] is True
    row = service.store.since("hotline-80", 0)[0]
    assert row.duration_ms == 1234
    assert row.as_json()["duration_ms"] == 1234


async def test_a_duration_that_beats_its_row_is_parked_and_applied_after(box):
    """Measured on a real session, not guessed: `PostToolUse` landed 244 ms
    after `PreToolUse` for a trivial Bash call, which is less than it takes the
    nudge in front of it to read the transcript and commit. Dropping those would
    mean fast tools -- most of them -- never getting a duration bar, and it
    would look like the feature working badly rather than a race."""
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)

    answer = await service.hook({
        "session_id": "s1", "event": "PostToolUse",
        "tool_use_id": "toolu_late", "duration_ms": 147,
    })
    assert answer["timed"] is False and answer["parked"] is True
    assert service.tool_durations_unmatched == 0, "not a failure yet"

    # The row lands, and the next read of this agent's transcript places it.
    service.store.append_event("hotline-80", "tool", "echo hi", tool="Bash",
                               tool_use_id="toolu_late")
    service._flush_durations("hotline-80")

    assert service.store.since("hotline-80", 0)[0].duration_ms == 147
    assert service._pending_durations.get("hotline-80") in (None, {})


async def test_durations_that_never_find_a_row_are_bounded_and_counted(box):
    """The app draws no duration bar for those rows, which is correct. A rising
    count is the only way to tell that from "nothing ran", and the dict that
    holds them must not grow quietly on an agent whose reads have stopped."""
    from hotline_ios.daemon import PENDING_DURATIONS

    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)

    for i in range(PENDING_DURATIONS + 5):
        await service.hook({"session_id": "s1", "event": "PostToolUse",
                            "tool_use_id": f"toolu_{i}", "duration_ms": i})
    service._flush_durations("hotline-80")

    assert len(service._pending_durations["hotline-80"]) == PENDING_DURATIONS
    assert service.tool_durations_unmatched == 5


async def test_a_post_tool_nudge_does_not_re_read_the_transcript(box):
    """It exists for one column. Tailing on it would double every read."""
    box.declare("hotline-80", "s1")
    box.live("s1")
    service = service_for(box)
    reads = []

    async def counted(agent, session_id, *, turn_ended=False):
        reads.append(agent)
        return FakeIngested(None)

    service.ingest_session = counted
    await service.hook({"session_id": "s1", "event": "PostToolUse",
                        "tool_use_id": "x", "duration_ms": 1})
    assert reads == []


def test_a_row_says_nothing_rather_than_null_when_it_has_no_duration(box):
    """A present-but-null field is a second way to say absent, and the app has
    to distinguish "no bar" from "a bar of zero"."""
    service = service_for(box)
    stored = service.store.append_event("hotline-80", "tool", "ls", tool="Bash")
    assert "duration_ms" not in stored.as_json()
    assert "client_token" not in stored.as_json()


# ---- honesty ---------------------------------------------------------------


async def test_hangup_does_not_claim_to_have_stopped_anything(box):
    """It cancels the daemon's own wait. The agent keeps running, untouched, and
    never learns this happened -- so the field says so rather than leaving a
    caller to assume the obvious."""
    service = service_for(box)
    service._open_conversation(None, "ring")
    conversation = next(iter(service.calls))

    out = await service.hang_up(conversation)
    assert out["ended"] is True
    assert out["process_stopped"] is False

    # Also on a call it has never heard of: idempotent, and still not a claim.
    assert (await service.hang_up("nope"))["process_stopped"] is False


async def test_the_control_endpoints_answer_over_real_http(box):
    """The routes exist and carry their refusals as status codes, not as a 200
    with an error in the body."""
    box.declare("headless", "s1")
    box.live("s1", tmux=None, status="busy")
    service = service_for(box)
    server = await run_server(service, 18840)
    try:
        health = await asyncio.to_thread(get, 18840, "/health")
        assert [c["id"] for c in health["globalControls"]] == ["new"]

        with pytest.raises(urllib.error.HTTPError) as raised:
            await asyncio.to_thread(post, 18840, "/api/v1/agents/stop", {"agent": "headless"})
        assert raised.value.code == 409
        assert "headless" in json.loads(raised.value.read())["error"]

        killed = await asyncio.to_thread(
            post, 18840, "/api/v1/agents/kill", {"agent": "headless"})
        assert killed == {"agent": "headless", "outcome": "stopped"}
    finally:
        await server.close()


async def test_say_and_reply_echo_the_client_token(box):
    service = service_for(box)
    out = await service.say("look at the build", None, client_token="tok-1")
    assert out["client_token"] == "tok-1"
    assert await eventually(lambda: any(
        e.client_token == "tok-1" for e in service.store.since("(unattributed)", 0)
    ))

    conversation, _ = service._open_conversation(None, "ring")
    answered = await service.reply(conversation, "yes", client_token="tok-2")
    assert answered["client_token"] == "tok-2"
    rows = service.store.conversation_events(conversation)
    assert [r.client_token for r in rows if r.kind == "you"] == ["tok-2"]


async def test_a_live_session_that_never_declared_itself_is_still_addressable(box):
    """It is a row on his roster under its derived name -- mostly his own shells
    -- so every control the app offers on it has to reach it. It used to 404
    while the app showed the buttons as available."""
    box.live("s9", name="data-88", tmux="hl-shell:@1.%1", status="busy")
    service = service_for(box)

    row = next(r for r in service.agents()["agents"] if r["name"] == "data-88")
    assert {c["id"] for c in row["controls"] if c["enabled"]} >= {"stop", "kill"}

    assert await service.stop("data-88") == {"agent": "data-88", "interrupted": True}
    assert box.calls == [("interrupt", "hl-shell:@1.%1")]


def test_elapsed_prefers_when_the_agent_started_over_when_this_store_noticed(box):
    """A live session that never declared itself has been running since its
    descriptor says, not since this database first wrote a row for it -- which
    for one of his own shells can be hours late and would draw an ELAPSED of a
    few seconds on something that has been up all day.

    The descriptor writes milliseconds and the rest of this wire is seconds.
    """
    session = box.live("s9", name="data-88")
    session.started_at = 1787701448731
    service = service_for(box)

    row = next(r for r in service.agents()["agents"] if r["name"] == "data-88")
    assert row["declaredAt"] == pytest.approx(1787701448.731)


def test_a_live_agent_is_never_asked_whether_it_could_be_resumed(box, monkeypatch):
    """`brief_for` globs the projects directory and reads the handoff file, and
    the roster is recomputed on every request and on every pass of a parked
    long-poll. Paying that per live agent to answer a question whose answer is
    always "it is still running" would make the roster cost scale with his
    disk."""
    asked = []
    monkeypatch.setattr(hotline.revive, "brief_for", lambda agent: asked.append(agent))
    box.declare("running", "s1")
    box.live("s1", tmux="hl-80:@1.%1")
    box.declare("gone", "s2")

    found = {row["name"]: row for row in service_for(box).agents()["agents"]}

    assert [r.name for r in asked] == ["gone"]
    assert {c["id"]: c for c in found["running"]["controls"]}["resume"]["enabled"] is False
