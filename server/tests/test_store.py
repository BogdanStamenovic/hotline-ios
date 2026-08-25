"""The store, on its own, with no daemon and no clock.

Every assertion here is synchronous and against injected timestamps. The store
is the one layer where a timing-dependent test would be pure self-harm: it is a
synchronous database and there is nothing to wait for.
"""

import sqlite3

import pytest

from hotline_ios.store import ROSTER_KIND, Store


@pytest.fixture
def store(tmp_path):
    s = Store(tmp_path / "hotline-ios.db")
    try:
        yield s
    finally:
        s.close()


def test_a_missing_database_file_is_created_not_fatal(tmp_path):
    # The daemon boots before anything has ever written a row, and on a box
    # where the state directory does not exist yet. Neither is an error.
    path = tmp_path / "nested" / "deeper" / "hotline-ios.db"
    assert not path.exists()
    store = Store(path)
    try:
        assert path.exists()
        assert store.stats()["db_ok"] is True
        assert store.history("nobody") == ([], False)
    finally:
        store.close()


def test_what_one_instance_writes_the_next_one_reads(tmp_path):
    """The whole reason this file exists: a restart must not lose his question."""
    path = tmp_path / "hotline-ios.db"
    first = Store(path)
    first.open_conversation("c1", "hotline-80", "ring", opened_at=1000.0, waiting_since=1000.0)
    first.append_event("hotline-80", "claude", "may I spend money", conversation_id="c1", at=1000.0)
    first.close()

    second = Store(path)
    try:
        events, _ = second.history("hotline-80")
        assert [e.text for e in events] == ["may I spend money"]
        assert second.conversation("c1")["agent_name"] == "hotline-80"
        assert second.blocked_since() == {"hotline-80": 1000.0}
    finally:
        second.close()


def test_the_sequence_is_global_not_per_conversation(store):
    store.open_conversation("c1", "a", "ring", opened_at=1.0)
    store.open_conversation("c2", "b", "say", opened_at=2.0)
    first = store.append_event("a", "claude", "one", conversation_id="c1", at=1.0)
    second = store.append_event("b", "you", "two", conversation_id="c2", at=2.0)
    third = store.append_event("a", "you", "three", conversation_id="c1", at=3.0)
    # Interleaved across agents and conversations, and still strictly ordered.
    assert [first.seq, second.seq, third.seq] == sorted([first.seq, second.seq, third.seq])
    assert len({first.seq, second.seq, third.seq}) == 3


def test_history_and_the_live_stream_meet_exactly_once(store):
    """The seam the whole cursor design exists to make trivial.

    A phone scrolls back through `history()` and follows forward through
    `since()`. If those two overlap he sees a line twice; if they leave a hole he
    silently loses one. Asserting disjoint-and-complete is the only way to know
    which, and it needs no clock at all.

    NOTE: the plan's §8 wording ("their union is exactly all N") only holds if
    `history(before=None)` returned the OLDEST page. It returns the NEWEST one,
    because that is what a phone opening a channel wants to see first. The
    property that actually matters is unchanged and is what is asserted here:
    across the seam there is no duplicate and no hole, from the page's oldest
    event forward.
    """
    store.open_conversation("c1", "hotline-80", "ring", opened_at=0.0)
    total = 17
    for i in range(total):
        store.append_event("hotline-80", "tool", f"event {i}", conversation_id="c1", at=float(i))

    page, has_more = store.history("hotline-80", limit=6)
    assert has_more is True
    assert len(page) == 6
    newest_seq = page[-1].seq

    tail = store.since("hotline-80", newest_seq)
    behind = {e.seq for e in page}
    ahead = {e.seq for e in tail}
    everything = store.since("hotline-80", 0)
    assert len(everything) == total
    assert behind & ahead == set()
    assert behind | ahead == {e.seq for e in everything if e.seq >= page[0].seq}
    # And walking back one more page meets the first one the same way.
    older, _ = store.history("hotline-80", before=page[0].seq, limit=6)
    assert {e.seq for e in older} & behind == set()
    assert max(e.seq for e in older) < page[0].seq


def test_paging_backwards_walks_the_whole_history_without_repeating(store):
    for i in range(10):
        store.append_event("a", "tool", f"e{i}", at=float(i))
    seen: list[int] = []
    before = None
    while True:
        page, has_more = store.history("a", before=before, limit=3)
        assert all(e.seq not in seen for e in page)
        seen = [e.seq for e in page] + seen
        if not has_more:
            break
        before = page[0].seq
    assert len(seen) == 10
    assert seen == sorted(seen)


def test_roster_ticks_ride_the_same_sequence_but_never_the_transcript(store):
    store.append_event("a", "claude", "real", at=1.0)
    tick = store.append_roster_event("a", "state: idle -> working", at=2.0)
    store.append_event("a", "you", "also real", at=3.0)

    # Same cursor space -- the tick consumed a seq.
    assert tick > 0
    assert [e.text for e in store.since("a", 0)] == ["real", "also real"]
    assert [e.text for e in store.history("a")[0]] == ["real", "also real"]
    assert [e.seq for e in store.roster_since(0)] == [tick]
    assert store.roster_since(tick) == []
    assert all(e.kind == ROSTER_KIND for e in store.roster_since(0))


def test_blocked_since_reports_the_earliest_question_not_the_latest(store):
    store.open_conversation("old", "a", "ring", opened_at=100.0, waiting_since=100.0)
    store.open_conversation("new", "a", "ring", opened_at=200.0, waiting_since=200.0)
    assert store.blocked_since() == {"a": 100.0}
    # Answering the first leaves him blocked on the second, not unblocked.
    store.mark_answered("old")
    assert store.blocked_since() == {"a": 200.0}
    store.close_conversation("new")
    assert store.blocked_since() == {}


def test_a_say_does_not_count_as_blocked(store):
    # He is not the one being waited on when he delegates work.
    store.open_conversation("c", "a", "say", opened_at=1.0)
    store.append_event("a", "you", "go and do it", conversation_id="c", at=1.0)
    assert store.blocked_since() == {}


def test_retire_round_trips_and_touches_no_history(store):
    store.append_event("a", "claude", "something", at=1.0)
    assert store.agent("a")["retired_at"] is None
    at = store.set_retired("a", True)
    assert at is not None and store.agent("a")["retired_at"] == at
    assert len(store.since("a", 0)) == 1
    assert store.set_retired("a", False) is None
    assert store.agent("a")["retired_at"] is None
    assert len(store.since("a", 0)) == 1


def test_a_dry_run_counts_honestly_and_deletes_nothing(store):
    store.open_conversation("c1", "a", "ring", opened_at=10.0)
    for i in range(4):
        store.append_event("a", "tool", f"e{i}", conversation_id="c1", at=10.0 + i)

    preview = store.purge("a", dry_run=True)
    assert preview["events"] == 4
    assert preview["conversations"] == 1
    assert preview["oldest_at"] == 10.0
    assert preview["dry_run"] is True
    # Nothing moved.
    assert len(store.since("a", 0)) == 4
    assert store.history_generation("a") == 0


def test_a_real_purge_deletes_rows_and_bumps_the_generation(store):
    store.open_conversation("c1", "a", "ring", opened_at=10.0)
    for i in range(4):
        store.append_event("a", "tool", f"e{i}", conversation_id="c1", at=10.0 + i)
    before = store.history_generation("a")

    done = store.purge("a")
    assert done["events"] == 4
    assert store.since("a", 0) == []
    assert store.conversation("c1") is None
    # The client's only signal that its cache is now a lie.
    assert done["history_generation"] == before + 1
    assert store.history_generation("a") == before + 1
    # The agent itself survives a history purge.
    assert store.agent("a") is not None


def test_purging_everything_drops_the_agent_row(store):
    store.open_conversation("c1", "a", "ring", opened_at=1.0)
    store.append_event("a", "tool", "e", conversation_id="c1", at=1.0)
    done = store.purge("a", scope="everything")
    assert done["agent_removed"] is True
    assert store.agent("a") is None
    assert store.since("a", 0) == []


def test_purging_everything_refuses_to_be_narrowed(store):
    store.open_conversation("c1", "a", "ring", opened_at=1.0)
    store.append_event("a", "tool", "e", conversation_id="c1", at=1.0)
    with pytest.raises(ValueError):
        store.purge("a", scope="everything", conversation_id="c1")
    with pytest.raises(ValueError):
        store.purge("a", scope="everything", before_seq=99)
    # Refused, not half-done.
    assert store.agent("a") is not None
    assert len(store.since("a", 0)) == 1


def test_purge_narrows_to_one_conversation(store):
    store.open_conversation("keep", "a", "ring", opened_at=1.0)
    store.open_conversation("drop", "a", "ring", opened_at=2.0)
    store.append_event("a", "tool", "kept", conversation_id="keep", at=1.0)
    store.append_event("a", "tool", "gone", conversation_id="drop", at=2.0)

    store.purge("a", conversation_id="drop")
    assert [e.text for e in store.since("a", 0)] == ["kept"]
    assert store.conversation("drop") is None
    assert store.conversation("keep") is not None


def test_purge_before_a_cursor_keeps_the_recent_end(store):
    store.open_conversation("c", "a", "ring", opened_at=1.0)
    seqs = [
        store.append_event("a", "tool", f"e{i}", conversation_id="c", at=float(i)).seq
        for i in range(6)
    ]
    cut = seqs[3]
    store.purge("a", before_seq=cut)
    left = store.since("a", 0)
    assert [e.seq for e in left] == seqs[3:]
    # Still open, so the conversation row stays even though half of it went.
    assert store.conversation("c") is not None
    # A hole in the sequence is fine; the cursor is a `>` on a primary key.
    assert left[0].seq == cut


def test_an_event_for_an_unknown_agent_creates_the_agent(store):
    # Foreign keys are ON, so this is not incidental -- it is what stops an
    # event landing in a phantom bucket.
    store.append_event("brand-new", "tool", "hello", at=1.0)
    assert store.agent("brand-new") is not None


def test_a_conversation_cannot_point_at_a_conversation_that_is_gone(store):
    # Proves foreign_keys=ON is actually on, rather than assumed.
    with pytest.raises(sqlite3.IntegrityError):
        store.db.execute(
            "INSERT INTO conversations (id, agent_name, kind, opened_at) VALUES (?,?,?,?)",
            ("c", "never-declared", "ring", 1.0),
        )


def test_health_stats_report_only_what_was_checked(tmp_path):
    store = Store(tmp_path / "db.sqlite")
    try:
        store.append_event("a", "tool", "x" * 500, at=1.0)
        stats = store.stats()
        assert stats["db_ok"] is True
        assert stats["db_bytes"] > 0
        assert stats["disk_free"] > 0
    finally:
        store.close()

    # A closed handle must read as not-ok rather than raising or lying.
    broken = store.stats()
    assert broken["db_ok"] is False
    assert "db_error" in broken


def test_roster_ticks_are_bounded_and_real_events_are_not(store):
    """A busy box with the app listening writes a tick every few seconds forever.

    Trimming those is NOT the automatic retention §3 rules out: that decision is
    about his history, and this touches none of it. A tick carries nothing that
    is not recomputable from the roster itself.
    """
    from hotline_ios.store import MAX_ROSTER_TICKS, ROSTER_TRIM_EVERY

    kept = store.append_event("a", "claude", "a real thing he said", at=1.0)
    for i in range(MAX_ROSTER_TICKS + 200):
        store.append_roster_event("a", f"change {i}", at=float(i))

    # A big explicit limit: roster_since() pages at MAX_PAGE, which is a cursor
    # concern and says nothing about how many rows are actually held.
    remaining = store.roster_since(0, limit=10_000)
    # The bound is approximate on purpose -- the trim runs once every
    # ROSTER_TRIM_EVERY appends rather than on each one -- so the count sits in
    # a band rather than on a number.
    assert MAX_ROSTER_TICKS <= len(remaining) <= MAX_ROSTER_TICKS + ROSTER_TRIM_EVERY
    # The newest survive; it is the stale end that goes.
    assert remaining[-1].text == f"change {MAX_ROSTER_TICKS + 199}"
    # And nothing of his was touched.
    assert [e.seq for e in store.since("a", 0)] == [kept.seq]


def test_trimming_only_ever_makes_a_client_refetch_too_often(store):
    """A cursor that falls behind the trimmed window still sees every remaining
    tick, so the failure direction is over-invalidation, never a missed one."""
    from hotline_ios.store import MAX_ROSTER_TICKS

    for i in range(MAX_ROSTER_TICKS + 100):
        store.append_roster_event("a", f"change {i}", at=float(i))
    store.trim_roster_events()
    remaining = store.roster_since(0, limit=10_000)
    assert len(remaining) == MAX_ROSTER_TICKS
    # An ancient cursor gets everything that is left rather than nothing: the
    # first page starts at the oldest surviving tick, not at the client's.
    page = store.roster_since(0)
    assert page[0].seq == remaining[0].seq
