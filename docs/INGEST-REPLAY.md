# Ingest is not transactional, and a replay duplicates rows

Found by a reviewer reading the 27 Aug prose change cold, not by its author.

## The mechanism

`daemon._ingest` does, in order:

    result = ingest.absorb(...)              # commits every row individually
    self.rates.observe(...)
    self.store.set_read_position(...)        # a separate, later commit

`Store.append_event` commits per INSERT. Nothing spans those writes and the
offset advance. So anything that stops the process in between -- an OOM kill, a
`systemctl restart` landing mid-ingest, an unhandled exception, power loss --
leaves the rows written and the offset unmoved, and the next read re-emits the
identical slice.

There is a second, larger path in the same function. When a stored offset is
found to be past the end of the transcript it names, `_ingest` resets it to 0
and re-reads **the entire file**. That branch is deliberate and correct for what
it was written for -- a position carried onto the shorter transcript of a
respawn under the same name -- and it is documented as having actually happened.
It replays everything already ingested for that session.

Nothing downstream collapses the result. `events` has an `AUTOINCREMENT`
primary key and no unique constraint; `since`/`history` are plain seq-ordered
scans; and the app keys rows by `"m\(moment.seq)"`, so a re-inserted row is a
new seq and renders as a second, separate message.

## Why it stopped being survivable on 27 August

This is older than the prose change. Until then a replay duplicated a `tool`
summary or a 240-character `outcome` caption -- ugly, deniable, easy to miss.
Storing assistant prose changed the blast radius: a replay now duplicates whole
multi-paragraph messages in his transcript.

## What is actually guarded, and what is not

**Guarded:** `claude` events. `ingest.absorb` calls `Store.has_event(agent,
"claude", at, text)` first and skips the insert if that exact row is already
there. `at` comes from the transcript record and `text` is the block verbatim,
so both survive a re-read unchanged -- which is what makes them a usable
identity for a replayed row. The `events_at` index on `(kind, at)` carries the
lookup.

**Not guarded:** `tool`, `phase`, `outcome`, `compact`. A replay still
duplicates those, exactly as it did before. `phase` and `outcome` carry fresh
`uuid4` ids per absorb, so they cannot be matched on identity at all without a
real key.

**The real fix, not done here:** one transaction spanning the slice's writes and
the offset advance, so a crash rolls back to a consistent point. That means a
batching API on `Store` and changing `append_event`'s commit-per-insert, in a
daemon he depends on from a train with no easy way to take a fix. The guard
above removes the damage that actually shows; this is the note saying the rest
is still there.

## Reproducing it

`tests/test_map.py::test_a_replayed_slice_does_not_post_the_prose_twice`
absorbs the same slice twice. It was checked in both directions: with the guard
removed it fails, with it present it passes.
