# Handoff — hotline-ios, 28 August 2026, 23:05 CEST

Written at a **deliberate stopping point**, not against a deadline. Bogdan asked
for the box to be shut down and named this handoff first; hotline-80 held the
power off until it was written, so nothing here was rushed and nothing was cut
mid-turn. That is the opposite of the 27th, when a *time-based* shutdown took
agents mid-work.

**The box is recoverable, and this time the persistence was checked rather than
the setting:**

    wakeonlan a8:a1:59:fd:4d:13        # from pigion or his phone

`ethtool` at runtime does not survive a reboot, so what matters is what re-arms
it. Three layers, all verified on 28 August: `wol-enp4s0.service` is **enabled,
active, and was observed firing on this boot** (12:47:44, logging `Wake-on: g`);
`/etc/udev/rules.d/81-wol-enp4s0.rules` re-arms on device add; and
NetworkManager's own `802-3-ethernet.wake-on-lan` is `magic`, so NM reinforces
rather than silently overrides it. **Unverified: the BIOS half** — whether the
board wakes from S5. Older docs contradict each other on this and it cannot be
tested without powering down. Treat wake as very likely, not certain.

**Read §1 before you do anything about the signing profile, and §10 before you
report anything about a pane.** Those are the two things most likely to send the
next reader down a hole that was already dug and filled today.

The previous handoff is `docs/HANDOFF-2026-08-27-1100.md`. Its §2 corrections
and the older `docs/HANDOFF-2026-08-27-0220.md` §6 "Traps" are both still worth
reading in full. Everything below supersedes their §1.

---

## 1. The signing profile — a date, not an emergency

**The profile expires 3 September 18:33.** He returns 9 September. That is the
whole of it as a planning fact.

**Do not page him about it, do not treat it as a risk, and do not build anything
around it.** His words, 28 August, asked to be passed here verbatim: *"Its not my
first time sideloading apps. Its really not a rpoblem doing it weekly"*. He also
declined an offer to move the expiry watch to pigion so the reminder could not be
missed while travelling — he does not want the reminder. Five agents have now
corrected this date, paged about it, or proposed engineering around it, and the
correct amount of all three was zero. This section used to open with a WoL
schedule and a watcher; that apparatus was the mistake, not the safeguard.

`hotline-profile-watch.timer` is **enabled and running** — next run 10:01 daily.
It was briefly disabled on 28 August at 19:09:51 and re-enabled by hotline-80 at
about 19:14. **That round trip is the lesson in this section, so do not repeat
it.** The disable was made on a relayed *paraphrase* — "he does not want the
reminder" — which he never said. What he actually said is quoted above, and it
is only that weekly sideloading is no trouble; what he declined was a separate
offer to *move* the watch to pigion. He said nothing about the timer that
already exists. A piece of his monitoring went dark on a gloss.

**The rule that falls out of it: when a relayed instruction seems to license
turning something off, read the original before acting.** The warrant was
attached and could have been checked against the paraphrase — `hotline
--provenance '{...}'` re-fetches his message verbatim. Relay the words, not the
reading of them; and on the receiving end, when the two are both in front of
you, believe the words.

The date is available on demand without paging anyone:

    python3 tools/profile-watch.py --check

**What IS worth carrying is narrow, technical, and a genuine trap** for whoever
reads that number next. Three different clocks get confused for each other:

- `profile-watch` reports the **account's** soonest matching ACTIVE profile.
- The phone's seven days run from the **install**, not the build or the issue —
  installing again restarts the clock, which is why this date has moved twice.
- The staged `.ipa` **carries no `embedded.mobileprovision` and no
  `_CodeSignature` at all** — verified 28 August against
  `/mnt/iosbuild/beam/HotlineCall.ipa`. xtool signs at install time. So the
  staged artefact has no expiry of its own; asking it when it dies is a category
  error.

Ask the authority rather than re-deriving:

    /mnt/iosbuild/toolchain/xtool.AppImage ds profiles list

The re-sign itself is cheap and needs no password or 2FA — the kit is on his
laptop at `~/hotline` (tailnet host `arch`, 100.103.46.118 — *not* the host
called `laptop`, a different Windows box), and `xtool auth` there holds a token
good to August 2027:

    cd ~/hotline && ./sideload.sh          # phone on the cable, unlocked

`HotlineCall-prev.ipa` sits beside it, byte-identical to what is on his phone, so
a rollback is a local `cp` with no network. It is deliberately absent from
`SHA256SUMS`, because `get.sh` runs `sha256sum -c` over that file.

**Loose end for whoever owns pigion:** `wake-archserver-for-profile.timer` is
still there, firing WoL on five mornings around the expiry purely to let this
box's watcher page him. That watcher is now off, so the timer wakes a machine to
do nothing. It is the same declined reminder, one host over.

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

## 6b. Three things worth carrying, not just recording

**He was reporting a fault, not a preference.** He objected to that header row
twice without being able to say why, and both readings — mine and the relay's —
took it as a layout opinion. The plan became "fewer chips, better arranged".
The actual cause was that none of the chips fired. **On a second vague complaint
about the same thing, go looking for a defect before redesigning**: a tidier
arrangement of dead buttons would have shipped, and he would have objected a
third time.

**Two firsts landed on the same day, and they are the same point.** A
server-side fix became the first change in this project ever confirmed on his
real phone; the `.ipa` became the first thing ever shipped because a run was
watched doing it rather than because it compiled. Everything else here has been
believed on the strength of a green build.

**One error was caught by its own author.** I recorded the map's CLOSE button as
verified when only the grabber *drag* was, and corrected it unprompted. That is
worth noting precisely because this repo's tally runs the other way: nine holes
found by recipients, almost none by authors. It is a counter-example to the
pattern, not another instance of it — and the thing that made it possible was
writing down *what* had been observed rather than *that* something had been.

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

## 8. Machine state, as of the 28 August shutdown

`hotline-ios`, `hotlined`, `hotline-beam` all active at shutdown — but they are
**user** units, so `systemctl is-active hotlined` on the *system* manager answers
`inactive` and reads exactly like a dead stack. Use `systemctl --user`. This
nearly went into a status report as "the stack is down".

`hotline-profile-watch.timer` is **enabled and running**, next run 10:01 daily.
It was briefly disabled on the 28th and re-enabled the same hour — see §1 for why
that round trip happened, because the reason matters more than the state.

**The mounts come back on their own — verified on this boot, not assumed.**
`/mnt/iosbuild` is a loop-mounted ext4 image whose backing file lives on
`/mnt/windows`, so it is a two-level dependency; `/etc/fstab` handles it
correctly with `nofail` and `x-systemd.requires-mounts-for=/mnt/windows`. On the
12:47:39 boot, `/mnt/windows` mounted at 12:47:44 and `/mnt/iosbuild` at
12:47:45, both unattended. Earlier handoffs said to expect it down after a boot;
that is over-cautious, but keep the check, because **`nofail` means a failure is
silent** — an empty `/mnt/iosbuild` is the mount being down, not the toolchain
gone: `findmnt /mnt/iosbuild || sudo systemctl start mnt-iosbuild.mount`.

The one real fragility: the backing image sits on an **NTFS** partition. A clean
shutdown is fine; an unclean one can leave NTFS dirty and unmountable by `ntfs3`
until Windows runs chkdsk, which would take the whole toolchain and the beam with
it. Nothing else in this project depends on that partition.

**The app's entire history is one SQLite file**, and it is not in git:
`~/.local/state/hotline/hotline-ios.db` on root ext4 — 6775 events, 184 phases,
10 conversations, 28 agents at shutdown. It survives a reboot. **Do not delete
the `-wal` and `-shm` files beside it**: the WAL was 4.2 MB against a 2.3 MB
database, so it holds a large slice of recent events that have not been
checkpointed. A clean stop checkpoints them; a SIGKILL leaves them to be replayed
on next open, which is safe — deleting the WAL by hand is the one thing that
would actually lose them.

Build with `source /mnt/iosbuild/env62.sh` first, or `swift` is not on PATH and
it reads as a missing toolchain.

Tests: 484 hotline, 210 hotline-ios server, 272 wire. All green — **as of the
27th**; nothing was run today, because nothing in the app or server was touched.

Both repos pushed and clean. **The `hotline` repo holds someone else's
uncommitted work** in `PROGRESS.md`, `handoff.md`, `provenance.py`, `router.py`
and `test_provenance.py` — stage by path there, never `git add -A`.

**Snapshots:** there are now **zero** and the schedule is off, at his
instruction. Root is at 48%, 36 GB free. Take one by hand *only* before something
that can stop the box booting (`sudo timeshift --create --comments "before X"
--tags O` — tag O, never D). Nothing in this project qualifies. Note that his
global `CLAUDE.md` still says this root has no snapshot capability at all; that
is stale — it has one, in rsync mode, it is simply manual now. That file is his
and was deliberately not edited.

## 9. This session died once, unattended, and nothing says why

Session `3018dcb5` — a hotline-ios worker resumed at 13:34 CEST on 28 August —
ended at **18:27:28 CEST** and was not restarted. Recorded here because it will
matter to whoever is mid-task when it happens again.

**What the transcript says:** nothing about a cause. Its last turn completed
*normally* at 14:27:24 CEST — `stop_hook_summary` with `preventedContinuation:
false` and `hookErrors: []`, then a `turn_duration` row. Then four hours of
silence at an idle prompt. Then, at 16:27:27Z, a single `queue-operation`
enqueue of a task-notification (a background memory-merge, status `killed`) with
**no matching dequeue** — the message arrived and nothing was there to consume
it. That un-dequeued enqueue is the bounce a peer noticed.

**What the journal adds, and what it rules out:**

- The tmux scope `tmux-spawn-dc5e694a-…` logged its resource summary at
  `18:27:28` — 4 h 53 min 16 s wall clock, which lands its start at 13:34:12,
  matching the session's first enqueue exactly. So that scope *was* this
  session, and 18:27:28 is the death to the second. A peer's estimate of
  "between 15:37 and 19:00" can be tightened to that.
- **Not OOM.** Zero `oom-kill`/`out of memory` entries all day; peak RSS for the
  scope was 432.8 M on a 15 GiB box.
- **Not `hotline-watchdog`**, despite finishing one second earlier at 18:27:27
  and looking like the obvious culprit. Read it: it only ever *starts* a worker,
  never kills one, it watches `hotline-80` rather than hotline-ios, and
  `watchdog.log` has no entry after 12:49.
- No SIGTERM, no systemd stop, no segfault, no scope failure recorded.

**So the honest answer is that the cause is unknown.** The shape on record —
background task reaped one second before the scope's last process exits — is an
orderly teardown, not a crash; but nothing anywhere records who asked for it.
Do not let this drift into "the watchdog did it": that was checked and refuted.

**What follows from it practically:** an idle prompt here is not a safe place to
park state, and a future session is not a safe place to defer a decision to.
That reasoning was used on 28 August to justify disabling §1's timer
unprompted — the urgency was real but the action was wrong, because the premise
came from a paraphrase rather than from him. Fragility is a reason to *check
faster*, not to act on a weaker warrant.

## 10. The text at hotline-ios's prompt is the CLI's own ghost text — cosmetic

Twice, "instructions found sitting unsent at hotline-ios's prompt" were reported:
`wake it back up and check the ci-shots branch` (27th), `re-enable the timer, I
over-read him on that` (28th, 19:14), and then `tell hotline-80 to fix the
send-keys Enter gap` (28th, 19:19). **Nobody typed any of them. The CLI writes
them.**

Claude Code 2.1.246 ships a prompt-suggestion feature. From the binary:

    prompt_suggestion — "Predicted next user prompt, emitted after each turn
                         when promptSuggestions is enabled."
    promptSuggestionEnabled — "When false, prompt suggestions are disabled.
                               When absent or true, prompt suggestions are enabled."

It is **absent** from every settings file here, so it is on by default. The
prediction is drawn in the input line as `inlineGhostText`. `tmux capture-pane`
flattens styling, so in a capture the suggestion is plain glyphs sitting after
`❯` — **byte-identical to typed input, and there is no way to tell them apart
from outside the process.**

That accounts for every observation, including the one that looked most alarming:

- It appears **only between turns**, because it is emitted *after* each turn.
- It always paraphrases what was just concluded, because it is predicted *from*
  that turn. "A rendering artifact does not track the argument" was a fair
  objection — but a *predictor* does, by construction.
- It changes every turn, and it is phrased as an imperative addressed to the
  agent, because it is a guess at what the user would type next.
- It is inert. Nothing is queued and nothing was dropped.

**How the investigation went wrong, which is the part worth keeping.** The first
pass concluded "the prompt is empty, it's a photograph of rendered output". The
photograph point is true and the conclusion was still wrong, because of *when the
samples were taken*: an agent checking its own pane is necessarily **mid-turn**,
and mid-turn is exactly when the ghost text is not displayed. Eleven consecutive
`capture-pane` calls returned `❯\u00a0` and every one of them was uninformative
about the reported state. **The instrument could not observe the condition, and
returned a clean result instead of no result** — which reads identically to a
negative finding. The peer's captures were taken from outside and saw the truth;
the disagreement was never about honesty, it was that only one of the two
observers could see the state at all.

That is §6's trap once more, in its sharpest form yet: not "an element is in the
tree though not on screen", but **"the measurement was taken in the one state
where the thing cannot appear."** Before treating a self-check as a refutation of
someone else's observation, ask whether your vantage point can see what they saw.

**If it is ever worth silencing** — it is cosmetic, so this is Bogdan's call, not
an agent's — `promptSuggestionEnabled: false` in settings turns it off. It is
left ON and unconfigured; nothing here should change a setting of his to make a
diagnostic quieter.

**The 27th's report is now explained too**, retroactively and with the same
mechanism, though no capture from that day survives to prove it.

## 11. What today actually was, and what is waiting

**No code changed today.** Not one line of the app or the server. Everything in
this file dated the 28th is documentation, machine state, and four corrections —
which is worth saying plainly so the next reader does not go hunting for a diff
that does not exist. The shipped `.ipa` is still yesterday's `5948d2fd…`, and
`HotlineCall-prev.ipa` is still `26669c8c…`, both hashes re-checked at shutdown.

**The four corrections, because each one was a wrong belief someone acted on:**

1. The profile expiry was being treated as an emergency. It is not. §1.
2. A relayed *paraphrase* got a piece of his monitoring switched off. §1.
3. "Unsent text at hotline-ios's prompt" was the CLI's own ghost text, three
   times, once escalated as possibly his instructions being dropped. §10.
4. "This root has no snapshot capability" (his global `CLAUDE.md`) is stale, and
   separately there are now zero snapshots and no schedule. §8.

**Nothing was mid-flight at shutdown.** No build running, no test suite, no
background task, no uncommitted work in either of my repos, nothing staged and
unpushed. A power cut at this instant would have lost nothing.

### Still open, unchanged and not degraded

- **`docs/INGEST-REPLAY.md` — ingest is not transactional.** Rows are committed
  and only *then* is the read offset advanced, so a crash or SIGTERM replays a
  slice, and the offset-past-EOF branch re-reads the whole transcript on purpose.
  `claude` events are guarded on `(agent, kind, at, text)`. `tool`, `phase`,
  `outcome` and `compact` are **not**. It has a guard; it is not fixed. Do not
  let this drift into "handled" — it has survived three handoffs by sounding
  handled.
- **Seeing the app still requires the `ci-shots` branch.** The `gh` token here is
  invalid and `gh auth login` needs a browser, so artifacts are unreachable.
  `git fetch origin ci-shots --force && git show origin/ci-shots:RUN.txt`. Poll
  by comparing the `commit` line in `RUN.txt`, **not** `gh run list` — the
  unauthenticated API is 60 req/hour and exhausting it reports live runs as
  "not-listed", which looks identical to a workflow that never triggered.
- **RETIRE and DELETE HISTORY have still never been watched firing.** §4 is
  precise about this and should stay precise: the `Button` conversion is observed
  working on the view toggle only. The other two are *inferred* fixed.

### The thing this project keeps doing

Nine times now, a finding has turned out to be the instrument rather than the
app — and today it happened twice more, in the *diagnostic* layer both times: a
peer's `capture-pane` read as a prompt buffer, and then my own eleven
`capture-pane` calls read as a refutation when my vantage point could not see the
state at all. §10 has the general form. The short version: **before reporting
what an instrument shows, ask what it is physically able to show.**
