"""The daemon, driven over real HTTP against hotline's real server.

Skipped rather than faked when hotline is not importable: this test's whole
value is that it uses hotline's actual httpd.Server, so a stub version of it
would assert nothing. The skip is loud.

Calls are hotline-calld's since 2026-10-31 (the hotline-call repository). What
is left of them here is the seam: hotline-calld writes each call into this
store, this daemon forwards his typed answer and his dismissal back, proxies
`/api/v1/call`, and reports the doorbell's health. A real hotline.httpd server
stands in for hotline-calld where the seam needs one.
"""

import asyncio
import json
import urllib.error
import urllib.request

import pytest

hotline_httpd = pytest.importorskip(
    "hotline.httpd",
    reason="hotline not on sys.path -- run with PYTHONPATH=/home/bodas/data/hotline/src",
)

from ringing import ring

from hotline_ios.calld import CallDaemon
from hotline_ios.daemon import Service, build_server
from hotline_ios.store import UNATTRIBUTED


class Reply:
    def __init__(self, text): self.text = text; self.notice = ""


class FakePool:
    def __init__(self): self.asked = []
    async def ask(self, key, text, narrator=None, timeout=None, origin=None):
        self.asked.append((key, text, origin))
        return ("fresh", Reply("nothing is on fire"))


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


class FakeCalld:
    """hotline-calld's HTTP surface, recording what this daemon sent it."""

    def __init__(self, port, *, health=None, call=None):
        self.port = port
        self.got: list[tuple[str, dict]] = []
        self.health = health or {"ok": True, "fake": False, "ring_ready": True,
                                 "transport": "sip+confirmed", "rings_when_closed": True,
                                 "transports_available": ["sip"], "inbound": None,
                                 "can_talk": True, "degradations": ["something minor"]}
        self.call = call or (200, {"call_id": "abc123abc123", "state": "answered",
                                   "reply": "yes", "transcript": [], "fake": False})
        self.server = hotline_httpd.Server(["127.0.0.1"], port, log=lambda m: None)

        @self.server.route("GET", "/health")
        async def health(request):
            return 200, self.health

        @self.server.route("POST", "/api/v1/call")
        async def call(request):
            self.got.append(("/api/v1/call", request.json()))
            status, body = self.call
            if status != 200:
                raise hotline_httpd.HttpError(status, body["error"])
            return 200, body

        for path in ("/api/v1/call/reply", "/api/v1/call/hangup"):
            async def forwarded(request, path=path):
                self.got.append((path, request.json()))
                return 200, {"known": True}
            self.server.route("POST", path)(forwarded)

    @property
    def client(self):
        return CallDaemon(url=f"http://127.0.0.1:{self.port}", api_key="")

    async def __aenter__(self):
        await self.server.start()
        return self

    async def __aexit__(self, *exc):
        await self.server.close()

    async def saw(self, path, *, within=3.0):
        for _ in range(int(within / 0.02)):
            found = [body for p, body in self.got if p == path]
            if found:
                return found
            await asyncio.sleep(0.02)
        return []


# ---- health: the doorbell is hotline-calld's, reported here -----------------


async def test_health_with_no_call_daemon_is_not_ok():
    # NOT ok when nothing can ring him. On 2026-08-25 /health reported ok:true
    # for 2.5 hours while every page went nowhere; a health check whose job is
    # to catch a dead pager must not pass when there is no pager at all.
    service = Service(FakePool())
    server = await run_server(service, 18790)
    try:
        body = await asyncio.to_thread(get, 18790, "/health")
        assert body["ok"] is False
        assert body["ring_ready"] is False
        assert body["calld"]["reachable"] is False
        assert any("nothing can ring him" in d for d in body["degradations"])
    finally:
        await server.close()


async def test_health_carries_the_call_daemons_doorbell_under_the_old_names():
    # The app's Health decoder reads ok, fake, transport, ring_ready and
    # degradations off this endpoint; they must keep arriving here.
    async with FakeCalld(18791) as calld:
        service = Service(FakePool(), calld=calld.client)
        server = await run_server(service, 18792)
        try:
            body = await asyncio.to_thread(get, 18792, "/health")
            assert body["ok"] is True and body["ring_ready"] is True
            assert body["fake"] is False
            assert body["transport"] == "sip+confirmed"
            assert body["transports_available"] == ["sip"]
            assert body["calld"]["reachable"] is True
            assert "calld: something minor" in body["degradations"]
        finally:
            await server.close()


async def test_health_says_so_when_the_call_daemon_is_down():
    service = Service(FakePool(), calld=CallDaemon(url="http://127.0.0.1:9", api_key=""))
    server = await run_server(service, 18793)
    try:
        body = await asyncio.to_thread(get, 18793, "/health")
        assert body["ok"] is False
        assert body["calld"]["reachable"] is False
        assert any(d.startswith("calld: unreachable") for d in body["degradations"])
    finally:
        await server.close()


# ---- /api/v1/call is forwarded, unchanged -----------------------------------


async def test_a_call_posted_here_is_placed_by_the_call_daemon():
    async with FakeCalld(18794) as calld:
        service = Service(FakePool(), calld=calld.client)
        server = await run_server(service, 18795)
        try:
            body = await asyncio.to_thread(
                post, 18795, "/api/v1/call", {"reason": "may I?", "source": "the build"}, 20)
            assert body["state"] == "answered" and body["reply"] == "yes"
            assert calld.got[0] == ("/api/v1/call", {"reason": "may I?", "source": "the build"})
        finally:
            await server.close()


async def test_a_refusal_from_the_call_daemon_keeps_its_status():
    # A registry call with no sip link is a 503 from hotline-calld; laundering
    # that into a 200 here would tell the caller it was delivered.
    async with FakeCalld(18796, call=(503, {"error": "needs the sip transport"})) as calld:
        service = Service(FakePool(), calld=calld.client)
        server = await run_server(service, 18797)
        try:
            with pytest.raises(urllib.error.HTTPError) as exc:
                await asyncio.to_thread(post, 18797, "/api/v1/call",
                                        {"reason": "x", "to": "sip:m@x"}, 20)
            assert exc.value.code == 503
            assert b"needs the sip transport" in exc.value.read()
        finally:
            await server.close()


async def test_a_call_with_the_call_daemon_down_is_a_503_so_hotline_call_falls_back():
    service = Service(FakePool(), calld=CallDaemon(url="http://127.0.0.1:9", api_key=""))
    server = await run_server(service, 18798)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(post, 18798, "/api/v1/call", {"reason": "x"}, 20)
        assert exc.value.code == 503
    finally:
        await server.close()


# ---- the conversation a ring opens ------------------------------------------


async def test_the_question_is_waiting_in_the_app_before_it_even_rings():
    # He must never answer a phone to silence. hotline-calld writes the
    # question here before it rings; the app finds it on the feed.
    service = Service(FakePool())
    server = await run_server(service, 18804)
    try:
        body = await asyncio.to_thread(
            ring, post, 18804, "may I spend money on a UI agency", source="the ios build")
        page = await asyncio.to_thread(
            post, 18804, "/api/v1/events",
            {"call_id": body["conversation"], "since": 0, "wait": 0})
        asked = [e for e in page["events"] if e["kind"] == "claude"]
        assert asked and "the ios build: may I spend money" in asked[0]["text"]
    finally:
        await server.close()


async def test_a_closed_ring_can_still_be_answered():
    # As of 2026-09-01 (his instruction, overriding SPEC 3) an unanswered ring
    # is marked unanswered and CLOSED -- but closing must not lose a late
    # answer, so a reply after the close still lands.
    service = Service(FakePool())
    server = await run_server(service, 18805)
    try:
        body = await asyncio.to_thread(ring, post, 18805, "ping")
        conversation = body["conversation"]
        await asyncio.to_thread(post, 18805, "/api/v1/conversations/append",
                                {"conversation": conversation, "kind": "state",
                                 "text": "unanswered"})
        await asyncio.to_thread(post, 18805, "/api/v1/conversations/close",
                                {"conversation": conversation})
        page = await asyncio.to_thread(
            post, 18805, "/api/v1/events", {"call_id": conversation, "since": 0, "wait": 0})
        assert page["closed"] is True
        assert "unanswered" in [e["text"] for e in page["events"] if e["kind"] == "state"]
        answered = await asyncio.to_thread(
            post, 18805, "/api/v1/reply", {"conversation": conversation, "text": "yes"})
        assert answered["delivered"] is True
    finally:
        await server.close()


async def test_his_reply_in_the_app_is_forwarded_to_the_waiting_call():
    """The contract that must survive the split.

    He answers by typing in the app; the agent blocked on `hotline-call` is
    waiting in hotline-calld, and gets his words only if this forwards them.
    """
    async with FakeCalld(18799) as calld:
        service = Service(FakePool(), calld=calld.client)
        server = await run_server(service, 18806)
        try:
            body = await asyncio.to_thread(ring, post, 18806, "may I spend money")
            await asyncio.to_thread(post, 18806, "/api/v1/reply",
                                    {"conversation": body["conversation"],
                                     "text": "yes, go ahead"})
            forwarded = await calld.saw("/api/v1/call/reply")
            assert forwarded == [{"conversation": body["conversation"], "text": "yes, go ahead"}]
        finally:
            await server.close()


async def test_a_reply_is_delivered_here_even_with_the_call_daemon_down():
    service = Service(FakePool(), calld=CallDaemon(url="http://127.0.0.1:9", api_key=""))
    server = await run_server(service, 18807)
    try:
        body = await asyncio.to_thread(ring, post, 18807, "ping")
        answered = await asyncio.to_thread(
            post, 18807, "/api/v1/reply", {"conversation": body["conversation"], "text": "yes"})
        assert answered["delivered"] is True
        for _ in range(100):
            if service.calld.forward_failures:
                break
            await asyncio.sleep(0.02)
        assert service.calld.forward_failures == 1
    finally:
        await server.close()


async def test_the_event_feed_replays_from_a_cursor_without_loss():
    service = Service(FakePool())
    server = await run_server(service, 18808)
    try:
        body = await asyncio.to_thread(ring, post, 18808, "status", context="the build")
        call_id = body["call_id"]
        first = await asyncio.to_thread(
            post, 18808, "/api/v1/events", {"call_id": call_id, "since": 0, "wait": 1})
        assert first["events"], first
        assert first["cursor"] >= 1
        # A reconnect from the same cursor -- what a wifi-to-cellular handover
        # looks like -- must not replay or lose anything.
        again = await asyncio.to_thread(
            post, 18808, "/api/v1/events",
            {"call_id": call_id, "since": first["cursor"], "wait": 0})
        assert all(e["seq"] > first["cursor"] for e in again["events"])
        assert first["gap"] is False
    finally:
        await server.close()


async def test_opening_a_call_is_idempotent_and_checks_what_it_is_given():
    service = Service(FakePool())
    server = await run_server(service, 18809)
    try:
        opened = await asyncio.to_thread(
            post, 18809, "/api/v1/conversations/open",
            {"conversation": "abcdef012345", "agent": None, "kind": "ring"})
        assert opened["existed"] is False and opened["agent"] == UNATTRIBUTED
        again = await asyncio.to_thread(
            post, 18809, "/api/v1/conversations/open",
            {"conversation": "abcdef012345", "agent": None, "kind": "ring"})
        assert again["existed"] is True
        for bad in ({"conversation": "../etc", "kind": "ring"},
                    {"conversation": "abcdef999999", "kind": "party"}):
            with pytest.raises(urllib.error.HTTPError) as exc:
                await asyncio.to_thread(post, 18809, "/api/v1/conversations/open", bad)
            assert exc.value.code == 400
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(post, 18809, "/api/v1/conversations/append",
                                    {"conversation": "fedcba543210", "kind": "you", "text": "x"})
        assert exc.value.code == 404
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(post, 18809, "/api/v1/conversations/append",
                                    {"conversation": "abcdef012345", "kind": "sent", "text": "x"})
        assert exc.value.code == 400
    finally:
        await server.close()


async def test_a_bad_call_id_is_404_not_an_empty_feed():
    service = Service(FakePool())
    server = await run_server(service, 18810)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(
                post, 18810, "/api/v1/events", {"call_id": "nope", "since": 0, "wait": 0})
        assert exc.value.code == 404
    finally:
        await server.close()


async def test_loopback_is_always_allowed_even_with_an_allowlist_set():
    # A blocked agent runs on THIS box, and must not be locked out of the phone
    # by the allowlist that exists to keep everyone else out.
    service = Service(FakePool(), allow_ips={"100.108.255.28"})
    server = await run_server(service, 18811)
    try:
        body = await asyncio.to_thread(ring, post, 18811, "x")
        assert body["conversation"] in service.calls
    finally:
        await server.close()


async def test_delegating_returns_a_conversation_and_the_answer_arrives_on_the_feed():
    """What the app actually does: send an instruction, follow the reply.

    The answer deliberately does NOT come back on this response -- a task can
    take minutes and an HTTP request open that long is one that dies on a
    network handover.
    """
    pool = FakePool()
    service = Service(pool)
    server = await run_server(service, 18801)
    try:
        sent = await asyncio.to_thread(
            post, 18801, "/api/v1/say", {"text": "what is the status", "agent": "hotline-80"})
        conversation = sent["conversation"]
        assert conversation

        seen: list[dict] = []
        for _ in range(50):
            page = await asyncio.to_thread(
                post, 18801, "/api/v1/events",
                {"call_id": conversation, "since": 0, "wait": 1}, 15)
            seen = page["events"]
            if any(e["kind"] == "claude" for e in seen):
                break
        kinds = [e["kind"] for e in seen]
        assert "you" in kinds and "claude" in kinds, seen
        assert next(e for e in seen if e["kind"] == "claude")["text"] == "nothing is on fire"

        # The turn must be labelled as typed rather than spoken: there is no STT
        # in this path any more, and claiming a mis-hearing risk that does not
        # exist makes the label useless where it does.
        _key, _text, origin = pool.asked[0]
        assert getattr(origin, "kind", "") == "phone"
    finally:
        await server.close()


async def test_saying_nothing_is_a_400():
    service = Service(FakePool())
    server = await run_server(service, 18802)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(post, 18802, "/api/v1/say", {"text": "   "})
        assert exc.value.code == 400
    finally:
        await server.close()


async def test_the_agent_list_survives_a_missing_registry():
    # It reads hotline's registry and live sessions; neither is guaranteed to be
    # there, and an empty list is a far better answer than a 500 on the one
    # screen he opens first.
    service = Service(FakePool())
    server = await run_server(service, 18803)
    try:
        body = await asyncio.to_thread(post, 18803, "/api/v1/agents", {})
        assert isinstance(body["agents"], list)
    finally:
        await server.close()


async def test_dismissing_a_conversation_closes_it_is_idempotent_and_tells_calld():
    # He can dismiss a question he is not going to answer. Doing it twice is a
    # 200, not a 404 -- the app can send it just after the agent gave up, and
    # turning that race into a failure shows him an error for something that
    # worked.
    async with FakeCalld(18812) as calld:
        service = Service(FakePool(), calld=calld.client)
        server = await run_server(service, 18813)
        try:
            body = await asyncio.to_thread(ring, post, 18813, "ping")
            conversation = body["conversation"]
            await asyncio.to_thread(post, 18813, "/api/v1/hangup", {"call_id": conversation})
            await asyncio.to_thread(post, 18813, "/api/v1/hangup", {"call_id": conversation})
            page = await asyncio.to_thread(
                post, 18813, "/api/v1/events", {"call_id": conversation, "since": 0, "wait": 0})
            assert page["closed"] is True
            assert {"call_id": conversation} in await calld.saw("/api/v1/call/hangup")
        finally:
            await server.close()


async def test_the_app_can_find_a_question_it_did_not_open():
    """The gap found by running it: a ring opens a conversation on the SERVER.

    The phone was not involved and has no id for it, so without a listing the
    question sits there and the app cannot find it.
    """
    service = Service(FakePool())
    server = await run_server(service, 18814)
    try:
        await asyncio.to_thread(ring, post, 18814, "may I spend money", source="the ios build")

        listing = await asyncio.to_thread(post, 18814, "/api/v1/conversations", {})
        rows = listing["conversations"]
        assert len(rows) == 1
        assert rows[0]["waiting"] is True
        assert "the ios build: may I spend money" in rows[0]["asked"]

        await asyncio.to_thread(
            post, 18814, "/api/v1/reply",
            {"conversation": rows[0]["conversation"], "text": "yes, go ahead"})

        after = await asyncio.to_thread(post, 18814, "/api/v1/conversations", {})
        assert after["conversations"][0]["answered"] is True
        assert after["conversations"][0]["waiting"] is False
    finally:
        await server.close()


async def test_replying_to_a_conversation_that_does_not_exist_is_a_404():
    service = Service(FakePool())
    server = await run_server(service, 18815)
    try:
        with pytest.raises(urllib.error.HTTPError) as exc:
            await asyncio.to_thread(
                post, 18815, "/api/v1/reply", {"conversation": "nope", "text": "hi"})
        assert exc.value.code == 404
    finally:
        await server.close()


def test_open_calls_ignores_closed_ones_and_reap_drops_them() -> None:
    """active_calls counted every conversation ever opened, so it only ever grew.

    Driven through the store now rather than by hand-building EventLogs, because
    the store is where a conversation lives; the old timestamp is still injected
    rather than waited for.
    """
    import time as _time

    service = Service(pool=None)
    old = _time.time() - 7200
    for call_id in ("a", "b", "c"):
        service.store.open_conversation(call_id, "hotline-80", "ring", opened_at=old)
        service.store.append_event("hotline-80", "claude", "?", conversation_id=call_id, at=old)
    service._hydrate()
    assert set(service.calls) == {"a", "b", "c"}
    assert service.open_calls() == 3

    service._close_conversation("a")
    service._close_conversation("b")
    assert service.open_calls() == 1
    # Only the closed and old ones go; the open one stays because he may still
    # answer it.
    assert service.reap(older_than=3600) == 2
    assert set(service.calls) == {"c"}
    # Evicted from the index, NOT deleted. Real deletion is purge and only
    # purge -- and a reaped conversation reads straight back in.
    assert service.store.conversation("a") is not None
    assert service._channel("a") is not None


async def test_an_unanswered_question_survives_a_restart_of_the_daemon():
    """The failure the store exists to remove.

    An unanswered ring used to live in a dict and die with the process, so a
    restart threw away the exact thing he was about to answer. Two Services over
    the same database in one test, which is what a restart is.
    """
    first = Service(FakePool())
    server = await run_server(first, 18820)
    try:
        body = await asyncio.to_thread(
            ring, post, 18820, "may I spend money", source="the ios build", agent="hotline-80")
        conversation = body["conversation"]
    finally:
        await server.close()
    first.store.close()

    second = Service(FakePool())
    server = await run_server(second, 18821)
    try:
        listing = await asyncio.to_thread(post, 18821, "/api/v1/conversations", {})
        rows = listing["conversations"]
        assert [row["conversation"] for row in rows] == [conversation]
        assert rows[0]["waiting"] is True
        assert "the ios build: may I spend money" in rows[0]["asked"]

        page = await asyncio.to_thread(
            post, 18821, "/api/v1/events", {"call_id": conversation, "since": 0, "wait": 0})
        assert [e["kind"] for e in page["events"]] == ["claude"]
        assert page["closed"] is False
        assert page["gap"] is False

        # And it is still answerable by a process that never opened it.
        answered = await asyncio.to_thread(
            post, 18821, "/api/v1/reply", {"conversation": conversation, "text": "yes"})
        assert answered["delivered"] is True
    finally:
        await server.close()


async def test_a_conversation_is_filed_under_the_agent_that_opened_it():
    service = Service(FakePool())
    server = await run_server(service, 18822)
    try:
        rung = await asyncio.to_thread(ring, post, 18822, "ping", agent="hotline-80")
        said = await asyncio.to_thread(
            post, 18822, "/api/v1/say", {"text": "status?", "agent": "hotline-80"})
        anonymous = await asyncio.to_thread(ring, post, 18822, "who am I")

        assert service.store.conversation(rung["conversation"])["agent_name"] == "hotline-80"
        assert service.store.conversation(said["conversation"])["agent_name"] == "hotline-80"
        assert service.store.conversation(rung["conversation"])["kind"] == "ring"
        assert service.store.conversation(said["conversation"])["kind"] == "say"
        # A ring naming no agent is the common case, not an error. It is filed
        # in a named bucket rather than dropped or given a phantom identity.
        assert service.store.conversation(anonymous["conversation"])["agent_name"] == UNATTRIBUTED

        # One channel, both conversations, one sequence.
        events = service.store.since("hotline-80", 0)
        assert {e.conversation_id for e in events} == {rung["conversation"],
                                                      said["conversation"]}
        assert [e.seq for e in events] == sorted(e.seq for e in events)
    finally:
        await server.close()


# ---- reachable from this box, not only from his phone ----------------------
#
# The daemon bound the tailnet address alone and the map hook was pointed at
# loopback. The hook is built to fail silently -- blanket except, always exit 0,
# a backoff marker file -- so every nudge died into a closed port and nothing on
# either side said a word. These pin the two halves of the fix: the bind, and
# the only thing that can notice when it is wrong again.


async def test_the_daemon_is_reachable_on_loopback_as_well_as_its_own_address():
    """`0.0.0.0` would also have fixed the hook. It would also have put a shell
    with bypassed permissions on whatever wifi this machine is on."""
    from hotline_ios.endpoint import LOOPBACK

    service = Service(FakePool())
    # 127.0.0.2 stands in for the tailnet address: a second loopback-range
    # address that exists on any Linux box, so the test binds two real sockets
    # without depending on tailscale being up.
    server = build_server(service, "127.0.0.2", 18830)
    await server.start()
    try:
        assert server.hosts == ["127.0.0.2", LOOPBACK]
        assert await asyncio.to_thread(get, 18830, "/api/v1/ping") == {"ok": True}
        on_tailnet = await asyncio.to_thread(
            lambda: json.loads(
                urllib.request.urlopen("http://127.0.0.2:18830/api/v1/ping", timeout=10).read()
            )
        )
        assert on_tailnet == {"ok": True}
    finally:
        await server.close()


async def test_health_verifies_the_hook_url_rather_than_remembering_it():
    service = Service(FakePool())
    server = await run_server(service, 18831)
    try:
        body = await asyncio.to_thread(get, 18831, "/health")
        assert body["hook_url"] == "http://127.0.0.1:18831/api/v1/hook"
        assert body["hook_reachable"] is True
        assert "127.0.0.1:18831" in body["listening_on"]
        assert not [d for d in body["degradations"] if "cannot reach" in d]
    finally:
        await server.close()


async def test_an_unreachable_hook_url_is_a_degradation_not_silence():
    """The whole point. A hook pointed at a closed port is invisible everywhere
    else by design, so this is the one surface that can report it."""
    service = Service(FakePool())
    server = await run_server(service, 18832)
    try:
        # Serving on 18832, but claiming the hook is told about a port nothing
        # is listening on -- exactly the shape the real defect had.
        service.listen_port = 18833
        body = await asyncio.to_thread(get, 18832, "/health")
        assert body["hook_reachable"] is False
        assert body["hook_url"] == "http://127.0.0.1:18833/api/v1/hook"
        assert any("cannot reach" in d for d in body["degradations"]), body["degradations"]
    finally:
        await server.close()


async def test_the_hook_installer_and_the_daemon_agree_on_the_url():
    """They were two independent constants that happened to disagree. This fails
    if anyone writes the address down a second time."""
    from hotline_ios import hooks
    from hotline_ios.endpoint import local_url

    assert hooks.DEFAULT_URL == local_url(hooks.HOOK_PATH)

    service = Service(FakePool())
    service.bound_to(["100.72.2.62", "127.0.0.1"], 8789)
    assert service.hook_url == local_url(hooks.HOOK_PATH, 8789)
