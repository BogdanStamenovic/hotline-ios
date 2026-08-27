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

## 3. Shipped at 23:20, and verified on a running app first

`HotlineCall.ipa` sha256 `5948d2fd…`, on his laptop, pigion and here.
`HotlineCall-prev.ipa` deliberately still `26669c8c…` — the build actually on
his phone, because a rollback target should be one known to work there.

The thread now defaults to his conversation (`sent` + his own messages) with the
transcript behind a button, and the header row is rethought rather than grown.
**He chose that default with the emptiness warning in front of him**, so it is
not softened and no old row is backfilled.

It was held all evening and released only when a simulator run showed each claim
true, which is the first time anything in this project shipped on observation
rather than on "it compiles":

    VIEW default sent=true tool=false prose=false
    VIEW full    sent=true tool=true  prose=true
    VIEW toggled=true
    PROSE chars=657 newlines=4 endsWithTail=true ellipsis=false
    VIEW map-close-worked routeGone=true chipBack=true

## 4. The tap bug — CLOSED, and it was never only mine

**Nothing in that header row had ever responded to a tap.** The chips were
`Chip` + `.onTapGesture`, and on a running simulator that resolved at a valid
on-screen frame with `isHittable == false`, inert to both a plain tap and a
coordinate tap. Wrapping the same `Chip` in a `Button` fixed it: same row, same
position, `hittable=true`, `toggled=true`.

**So `RETIRE` and `DELETE HISTORY` were dead since they shipped** — they carried
the identical pattern, and DELETE HISTORY was moved into that row precisely
because he could not find it anywhere else. That is very likely what his "rethink
that row" instinct was detecting. Converted with the rest.

Stated precisely, because the distinction matters: what is *observed* is that the
gesture form failed and the `Button` form works, on this row, measured. What is
*inferred* is that the other two chips failed for the same reason. Nobody has
watched RETIRE or DELETE fire.

Nothing was ever at risk from the dead delete: the chip only opens the purge
sheet, which has always required a 1500 ms hold against counts it re-checks
immediately before the destructive call. What he lost was the *ability* to
delete, not protection from deleting.

**The map's CLOSE button is now verified too** (`map-close-worked routeGone=true`).
Earlier notes claiming it was verified were wrong — what had been verified was
the grabber *drag*. It is observed now.

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
