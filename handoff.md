# Handoff — hotline-ios, 27 August 2026, ~23:10 CEST

Written against a possible midnight shutdown. **It is recoverable and that is
verified, not assumed:** `wakeonlan a8:a1:59:fd:4d:13` from pigion or his phone,
WoL proven end to end earlier today. Do not rush anything out ahead of it.

The previous handoff is `docs/HANDOFF-2026-08-27-1100.md`. Its §2 corrections
and the older `docs/HANDOFF-2026-08-27-0220.md` §6 "Traps" are both still worth
reading in full. Everything below supersedes their §1.

---

## 1. Dates, corrected twice today

**The profile expires 3 September 16:24. He returns 9 September.** The 2
September 04:16 in older docs is dead: the seven days run from *install*, and he
installed at 16:24 today, which restarted the clock. Ask the authority, never
re-derive:

    /mnt/iosbuild/toolchain/xtool.AppImage ds profiles list

**The re-sign is now cheap.** The kit is on his laptop at `~/hotline` (tailnet
host `arch`, 100.103.46.118 — *not* the host called `laptop`, which is a
different Windows box). `xtool auth` there is logged in with a token good to
**August 2027**, so it costs no password and no 2FA:

    cd ~/hotline && ./sideload.sh          # phone on the cable, unlocked

`HotlineCall-prev.ipa` sits beside it — byte-identical to what is on his phone —
so a rollback is a local `cp`, no network. It is deliberately absent from
`SHA256SUMS`, because `get.sh` runs `sha256sum -c` over that file.

`wake-archserver-for-profile.timer` on pigion fires WoL on five mornings around
the expiry so this box's watcher can page him. Best-effort: the BIOS half of WoL
is still unproven.

## 2. Live on his phone right now, no reinstall needed

Both are server-side, both confirmed by him or against the running daemon:

- **Prose arrives whole.** Assistant text was never stored; it reached the phone
  only as the phase `outcome`, which is one-lined to 240 characters because it
  is the *map's leg caption*. Any prose before a turn's last block was dropped
  outright. He confirmed the fix on his own phone: "it's a lot better this way".
- **The Discord bridge.** `hotline`'s pager mirrors a deliberate message to the
  app as well as Discord, as its own `sent` kind. Best-effort, cannot break the
  Discord path; failures counted to a state file and surfaced as
  `mirror_degraded` on hotline's `/health` (port 8788), detail on
  `/api/v1/mirror` behind the key.

## 3. Built, tested, and deliberately NOT shipped

The two-view app change: the thread defaults to his conversation (`sent` + his
own messages) with the transcript behind a button, and the header row is
rethought rather than grown. **He chose that default with the emptiness warning
in front of him**, so it is not softened and no old row is backfilled.

**The `.ipa` is held because of §4.** That is the right call at 23:55 as much as
at 20:00: a build whose new button may not respond is worse than no build, and
he already has a working app.

## 4. THE OPEN BUG — read this before touching the header

**The FULL TRANSCRIPT toggle does not fire.** Measured on a running simulator,
not inferred:

    frame 107,215 114x21 inside a 420x912 window
    isHittable = false
    plain tap: nothing.  coordinate tap: nothing.

Ruled out by reading: `chrome` leaves hitTesting default and its offset is zero
at rest; `.channel` is `hitTesting: e > 0.55`, true at rest; `BackStrip` is 44 pt
wide (the full width it receives is only the divisor in its drag maths); the
query resolves and returns the right label; the route chip in the same row takes
a drag. Geometry is dead — the frame is on screen.

**Last action taken:** the header controls are now `Button`s instead of `Chip` +
`.onTapGesture` (commit `c3579a9`), which is a fix and a diagnosis at once. **A
CI run for it was in flight when this was written — read its result first.**

**`RETIRE` and `DELETE HISTORY` carried the identical pattern.** If the tap never
fired for them, they have been dead since they shipped. **This is a hypothesis
with NO reading yet** — the run before last died mid-drive. Do not repeat it as
fact; he has already been told it is unconfirmed.

If it holds, the urgency is the opposite of what it looks like: what he lost is
the *ability* to delete, not protection from deleting. `Purge.swift` already
requires a 1500 ms hold against server counts it re-checks immediately before
the destructive call, so a working tap opens a confirmation and destroys
nothing.

## 5. How to see the app without a GitHub token

The `gh` token on this box is **invalid** and `gh auth login` needs a browser.
Artifacts are therefore unreachable. Do not waste an hour rediscovering that.

- CI pushes screenshots to an orphan **`ci-shots`** branch, fetched over SSH,
  which works. `git fetch origin ci-shots --force && git show origin/ci-shots:RUN.txt`
- `RUN.txt` carries the drive's MARK timeline, the `VIEW`/`PROSE` readings,
  **build errors and test failures**. Those last two were added because a
  compile error and a dead drive were each invisible to the one machine that
  could fix them.
- **The unauthenticated GitHub API is 60 requests/hour.** Polling `gh run list`
  every 30 s exhausts it and runs then report as "not-listed", which looks
  exactly like a workflow that never triggered. Poll by fetching `ci-shots` and
  comparing the `commit` line in `RUN.txt` instead.

## 6. What kept going wrong, because it will again

Four separate "findings" today were the instruments, not the app: a filmstrip
that never pointed at the thread; `final.png`, which is taken after teardown and
photographs a dead app; a view check that passed because the fixture contained
no prose to hide; and a substring that matched a fleet row behind the channel
because `app.staticTexts` is the whole tree, not the screen.

That is §6's own trap — an element is in the tree whether or not it is on the
screen — reappearing in the measuring layer. **When a machine can tell you, make
it tell you.** The two changes that broke the cycle were putting the compiler
error and the failure reason into `RUN.txt`.

## 7. Two open items that are real

- **`docs/INGEST-REPLAY.md`.** Ingest is not transactional: rows are committed
  and only then is the read offset advanced, so a crash or SIGTERM replays a
  slice, and the offset-past-EOF branch re-reads the whole transcript on
  purpose. `claude` events are guarded on `(agent, kind, at, text)`. `tool`,
  `phase`, `outcome`, `compact` are **not**. It has a guard, it is not fixed —
  do not let it drift into "handled".
- **The suite once wrote to his live app.** `mirror_sent` defaults to loopback,
  which here is his real daemon, and the pager's tests put 16 fixture strings
  into it. Removed. `conftest` now sets `HOTLINE_MIRROR=0` suite-wide and
  `tests/test_no_live_mirror.py` fails if that is ever dropped.

## 8. Machine state

`hotline-ios`, `hotlined`, `hotline-beam`, `hotline-profile-watch.timer` all
active. `/mnt/iosbuild` mounted — if it looks empty after a boot the mount is
down, not the toolchain gone: `findmnt /mnt/iosbuild || sudo systemctl start
mnt-iosbuild.mount`. Build with `source /mnt/iosbuild/env62.sh` first, or
`swift` is not on PATH and it reads as a missing toolchain.

Tests: 484 hotline, 210 hotline-ios server, 272 wire. All green.

Both repos pushed and clean. **The `hotline` repo holds someone else's
uncommitted work** in `PROGRESS.md`, `handoff.md`, `provenance.py`, `router.py`
and `test_provenance.py` — stage by path there, never `git add -A`.
