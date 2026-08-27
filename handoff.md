# Handoff — hotline-ios session, 27 August 2026 ~02:20 CEST

Written under a shutdown order. Assume this file is all you get.

**Remote wake — CHANGED after this file was first written, and still unproven.**
The original line here said a physical power-button press was the only way back.
`hotline-80` then reported it armed and tested the OS side: `wol-enp4s0.service`,
enabled, and it re-armed to `g` after being forced to `d`. **The cable and the
BIOS are his, and ErP must be DISABLED or the NIC gets no standby power.** I did
not test this myself and no magic packet has actually woken this box yet, so
treat WoL as unverified: hope for `wakeonlan a8:a1:59:fd:4d:13`, plan for a walk
to the power button.

## CORRECTIONS, 27 August 2026 ~10:30 CEST — read these before anything below

Three things this file states as fact are wrong. I found them by checking, not
by reasoning, and the rest of the file is only as good as the parts I re-tested.

1. **"I cannot compile Swift on this box" (§3) is FALSE.** The full toolchain is
   here and works: Swift 6.2.3 plus the 3.1 GB Darwin SDK, on the ext4 loop image
   at `/mnt/iosbuild`. A clean `.ipa` builds in **3.4 seconds**:

       source /mnt/iosbuild/env62.sh
       cd app/HotlineCall && /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa

   `docs/BUILDING.md` has documented this the whole time, including the exact
   trap that produced the false claim: `swift` is not on `PATH` until `env62.sh`
   is sourced, so "swift: command not found" reads as "no toolchain" when the
   truth is "not sourced". **You are not writing blind, and you do not need a
   13-minute CI round to know whether Swift compiles.**

2. **"Installing xtool on archserver ... is a system-wide install, so it needs
   his yes" (§4.1) is FALSE, twice.** xtool ships a self-contained AppImage, so
   no system-wide install exists to approve — and it is *already on this box*,
   at `/mnt/iosbuild/toolchain/xtool.AppImage`. The most urgent item in this
   file was never blocked on him at all.

3. **The 403 device-limit failure is resolved, not pending.** His phone is
   registered and `ENABLED` under team `3GAQP72Y5Z` (`25RYBYG6YU`), verified
   against Apple today. `docs/DEVICE-LIMIT.md` has the detail. Do not act on
   the "second Apple ID" option; it is not needed.

**And the plan changed, from him.** Asked to plug the phone into the workstation
before the profile expires, he answered:

> "I am comming back on the 9th but i got the arch laptop with me. You can beam
> it there"

So **he is away until 9 September and the profile expires 2 September 04:16** —
he is gone for the entire gap. The workstation cable is off the table. The
sideload has to run from the laptop that is physically with him
(`arch`, `100.103.46.118`, reachable passwordless over Tailscale), using
`tools/sideload.sh`. What still genuinely needs his hands, and cannot be routed
around: the cable, the Trust tap, and one `xtool auth login` on that laptop.

---

Repo: `/home/bodas/data/hotline-ios`, branch `main`, everything **pushed**.
HEAD when written: `5a958cc`.

---

## 1. Where I stopped, and the next concrete action

The last thing I did was a design pass on the channel (conversation) screen,
pushed as `5a958cc`. **CI run `33024383840` is green** — it compiles and the
simulator drive runs end to end.

**Next concrete action:** nothing is blocked and nothing is half-finished. The
highest-value next step is a decision, not a task — see §4. If you want code
work, the ranked list is in §5.

**Nothing from this session is on his phone.** The build on the device is still
the 04:16 one from 26 Aug (`MD5 41d2bc5a…`). Every change described here is
verified in CI only.

---

## 2. What I did this session (all pushed, all CI-green)

Commits in order:

| Commit | What |
|---|---|
| `3665a69` | Fixed the frame-timing metric (idle + jitter faults) |
| `c4797fa` | Added the control baseline (films Apple's Settings app) |
| `00a6694` | Row-tap fix attempt #1 — **reasoning was wrong**, superseded |
| `3cee7a2` | Row tap by visible frame + control recorder retry |
| `998b2f6` | Baseline-relative verdict + two-tap drive |
| `6411ed1` | Measure the floor before scoring the app against it |
| `5a958cc` | The design pass on the conversation screen |

### The jank question — ANSWERED, and it is not the app

This was the open question from the previous handoff. It is now settled.

The old `hitchy` verdict was an **artifact of a broken metric**, twice over:

1. Idle was scored as lateness. A static screen composites nothing, so "nothing
   moved for 20 s" arrived as one 20-second frame interval.
2. Worse: the recorder timestamps *capture*, not vsync, and quantises to the 600
   Hz media timescale. A flawless 60 fps stream comes back alternating ±1 tick
   around 16.67 ms, and `sum(max(0, d - budget))` rectifies that zero-mean
   jitter into pure "hitch time". **A synthetic perfect 60 fps stream scored 49
   ms/s — five times Apple's threshold — having dropped nothing.**

`ci/frametimes.py --self-test` now asserts both directions and runs in CI.

Then the control settled attribution. Same runner, same recorder, same gestures,
against Apple's own Settings app (UIScrollView-backed, smooth on real hardware):

| Run | App | Control (Settings) |
|---|---|---|
| 33013976756 | 23.06 % | 38.26 % |
| 33015245379 | 21.78 % | 47.46 % |
| 33024383840 | 21.64 % | 36.79 % |

**Apple's own app drops ~1.7× more frames than this app on the same runner.**
The rate is the runner's software rasteriser. `verdict` now reads
`at or below the floor`.

**Consequence: `ThreadView.staged`'s `AnyView` churn and the `animatableData`
main-actor hypothesis are NOT indicted by any of this.** The previous handoff
earmarked both for a profiler. Do not spend a week there on the strength of a
CI number — it was never about the app's code.

**Limit, stated plainly:** this clears the *CI measurement*, not the app. He
reported jank on the physical phone and this instrument cannot see that. Device
measurement is a different instrument and remains undone.

### The design pass (`5a958cc`)

I rendered the Kinetic Minimal mockup (artifact `961d3729-9ae2-4471-af65-67b6324da5a8`)
headless and put it beside his screenshot. Side by side the app read as a
monitoring dashboard with a log file under it. Four causes, none of them the
thread itself:

- **Sparkline + 4 telemetry cells sat on top of the transcript** → the first
  message started a third of the way down. `InstrumentStrip` now takes
  `showsGraph: Bool = true`; the channel header passes `false`. Numbers stay
  (APP-PLAN 11's ask, he reads them); the graph goes. `MapLayer` already draws
  the same samples where time is the axis.
- **`PHASE`/`OUTCOME`/`COMPACT` as a left label column** → made every route row
  a table row, and a screen of table rows is a log. The kicker moved above the
  sentence; the sentence gets full width.
- **A duration bar down the right of every tool row** → a numeric column, the
  other half of the table feel. Removed from the transcript. `duration` is
  untouched on the moment and **`MapLayer.swift:385` still draws it** (verified,
  not assumed). `DurationBar` had no callers left and was deleted.
- **A 120×2 orange rule under the title** → the one accent in the palette spent
  on decoration, above a state line whispering "Running" in grey. Rule removed;
  the state line took the colour — uppercase `.label(10.5)`, `Theme.sig` when
  blocked.

Before/after images are on disk at **`drop/design/`** (`drop/` is gitignored, so
they persist locally and cannot leak to the public repo):
`compare-transcript.png` (mockup vs app), `before-after.png`,
`mockup-transcript.png`, `mockup-transcript.html` (the rendered mockup, so you
do not need to re-fetch the artifact), `channel.png` (the after, from CI).

---

## 3. VERIFIED vs ASSUMED

**Verified — I ran it and read the output:**

- CI `33024383840` green, both jobs. The design changes compile and the drive
  runs end to end (26 marks, channel opens, map opens with `Route. 3 phases.`).
- The three app-vs-control numbers above, from the runs' own artifacts.
- `frametimes.py --self-test` passes both directions (in CI, this run).
- The metric bug — I reproduced it with a synthetic stream, it is not inference.
- `MapLayer.swift:385` renders `moment.duration`.
- ssh to the new `arch` laptop works passwordless, passwordless sudo confirmed.
- `profiler.service` active on archserver, managing his `.bashrc`/`.zshrc`.
- `hotline-ios.service` active, `/health` 200 on `100.72.2.62:8789`.
- `~/.config/xtool/data/XTLAuthToken` exists on archserver (dated 25 Aug).
- `drop/` is gitignored (`.gitignore:22`).

**Assumed / NOT verified — treat with suspicion:**

- **Nobody has seen the design changes on real hardware.** Simulator only.
- **I cannot compile Swift on this box.** There is no Mac. Every Swift change I
  made was verified *only* by the CI runner. If you edit Swift here, you are
  writing blind until a run comes back (~13 min).
- I did not re-measure whether removing the sparkline changed the frame numbers.
  The 21.64 % above is from the same run as the design change, but I did not
  isolate the two.
- The two-tap behaviour (§6) I explained via `swipeOutcome` arithmetic and the
  drive confirmed the *symptom*. I did not instrument the app to prove
  `swiped != nil` was the mechanism.

---

## 4. Open — waiting on Bogdan, not on code

1. **The provisioning profile expires 2 September 04:16** (not 1 Sep 22:53 —
   see the corrections at the top of this file). After
   that the app stops launching on his phone. **This is the most urgent item in
   this file.**

   It got worse this session: **the old laptop died** (8 years, motherboard
   snapped in two and hand-soldered for 3 of them; Windows BSOD photo in
   `drop/IMG_4246.jpg`). The signing setup died with it — `~/hotline/sideload.sh`,
   the xtool Apple ID login, and the `/var/lib/lockdown` pairing (which is
   **per-machine** and does not transfer).

   **The route that does not depend on the repair:** his Apple ID auth token is
   already on **archserver** at `~/.config/xtool/data/XTLAuthToken`. What is
   missing here is the xtool *binary* and a USB connection to the phone.
   Installing xtool on archserver + plugging the phone into this box removes the
   laptop from the critical path entirely. **It is a system-wide install, so it
   needs his yes.** I asked; he has not answered.

2. **The decide card's A/B option rows cannot be built without a server change.**
   `Waiting` (Wire.swift:351) carries `asked: String?` and **no options array**.
   The mockup shows two option cards; there is nothing to render them from and
   inventing two would be fiction on the one screen whose job is extracting a
   real decision. Server change if he wants it.

3. **`gh repo delete BogdanStamenovic/darwin-sdk-build`** still needs
   `gh auth refresh -h github.com -s delete_repo` from him. Unchanged from the
   last handoff.

4. **The three header chips** (`ROUTE·N` / `RETIRE` / `DELETE HISTORY`) — the
   mockup has one pill. I deliberately left them: he explicitly asked for
   somewhere to retire and delete, and hiding them to match a mockup would trade
   his requirement for my aesthetics. His call whether they move into the
   control sheet.

5. **The two-tap behaviour** (§6) — bug or correct iOS behaviour? His call.

---

## 5. Ranked next code work

1. **Nothing.** Seriously — the highest-value move is §4.1, and it is his
   decision, not a task.
2. If he says yes to xtool on archserver: install it, pair the phone here,
   sideload. That also puts the design changes on his phone.
3. Device-side jank measurement — the one thing the CI work could not answer.
4. `ThreadView.staged` `AnyView` churn — **only** if device measurement points
   there. CI does not.

---

## 6. Traps — things that look right and are not

- **`ssh arch 'cmd'` never sources `.zshrc`.** It is non-interactive. `zsh -lic`
  without a pty dies on `zle` then hangs on stdin. The only real login-shell
  test is `ssh -tt arch 'zsh -lic "…" < /dev/null'`. `arch-repair` caught this;
  a parse check that looks like it validated is worse than no check.
- **`zsh -n` proves parsing, not running.** It printed `ZSHRC_OK` on a config
  whose `ls` would have failed, because the aliases point at `eza`/`bat` which
  were not installed. Parse ≠ runtime. Same shape as the frametimes bug.
- **A backgrounded `&` and a PID are not proof a recorder is recording.** The
  control filmed *nothing* for a whole run while `testRunnerFloor` passed —
  `simctl` refused with `Resource busy / Host recording is already in progress`
  because the drive's SIGKILLed recorder still held the device. The workflow now
  waits for release and verifies. **This was my bug, and it is the same
  take-the-field-at-face-value mistake as the metric.**
- **`element.exists` ≠ on screen.** `FleetLayer` places every row absolutely, so
  a row scrolled past the top is still in the accessibility tree **with a
  negative frame**. The drive tapped `hotline-ios` at its own centre and hit
  **y = −32**, above the window. Use `visibleRow(_:)` in `DriveTests.swift`,
  which checks the frame against the window.
- **`isHittable` is a red herring here and I got this wrong once** (`00a6694`).
  It is false for *every* row by design — `FleetLayer.arbiter` is one
  `DragGesture(minimumDistance: 0)` over the whole surface, deliberately, so no
  per-row Button takes the touch. Do not build logic on it.
- **The `.xcresult` cannot be opened without a Mac**, and this project is driven
  from Linux. That is how "is a row hittable" stayed open for three runs. The
  drive now **prints** the accessibility tree on the no-channel path. Keep it
  that way; attaching-only is attaching to nobody.
- **The drive may need two taps to open a channel, and says so.** `endTap`'s
  first branch closes a swiped row and returns *without navigating* — standard
  iOS. Whether the preceding "close it again" drag leaves one open turns on
  release velocity: `swipeOutcome` puts that drag at x = +53.6 against an
  `openRight` threshold of 73.2, so it closes at rest and opens under any
  residual push. **This is real on his phone too:** swipe a row open, swipe it
  closed, and the next tap on any row is eaten.
- **`AnswerCard` already IS the mockup's decide card** (`Shell/SlamCard.swift:226`)
  — orange kicker, question in body, orange-stroked card. I initially reported it
  missing; that was wrong. It was absent from his screenshot because that agent
  was *running, not blocked*. The truncated `PHASE …` row there is a phase
  marker, not the question.
- **The composer send button is already correct** — `Circle().fill(ready ? Theme.ink : Theme.ink5)`.
  It looks grey in screenshots only because the field is empty. Do not "fix" it.
- **The scratchpad is under `/tmp` and does not survive a reboot.** Anything you
  want to keep goes in the repo (or `drop/`, which is gitignored). I rescued the
  design images already.
- **The Chrome extension is not connected** on this box, so
  `mcp__claude-in-chrome__*` fails with "Browser extension is not connected".
  Route around it: `google-chrome-stable --headless=new --screenshot` works and
  is how I rendered the mockup. `desktop` was already `on`.
- **`ownbox` is at `~/.local/bin/ownbox`, not on the non-interactive PATH.**
  `which ownbox` returns nothing from a tool call. Export the path first.
- **`profiler` is his own tool for keeping `.bashrc`/`.zshrc` in step — it is
  NOT a performance profiler.** I nearly went looking for a perf tool. It is
  already installed and running on archserver.

---

## 7. Machine state at shutdown

- **archserver** — `hotline-ios.service` and `hotline-sipprobe.service` active;
  came back by themselves on the 21:23 boot, which is the linger mechanism
  working as designed. `profiler.service` active.
- **`arch` (the NEW laptop, same name as the dead one)** — `100.103.46.118`,
  Tailscale up, sshd up, passwordless ssh + sudo from archserver. Terminal setup
  replicated from archserver by `arch-repair`: 12 packages + carapace, configs
  copied, `chsh` to zsh, validated interactively. Backup of what it had before:
  `~/.config-backup-LATEST` on arch.
- **`known_hosts` on archserver** — I removed three stale `arch` host keys from
  the dead laptop and recorded the new one, after checking the new key's
  fingerprint matched what the server presented (`SHA256:M0w1E+HL…lCzg`).
  `ssh-keygen -R` left its own `.old` backup.
- **`profiler` is NOT on arch.** Natural follow-on if he wants the laptop's bash
  and zsh kept in step the way archserver's are. He has not asked.
- Peer sessions at write time: `arch-repair`, `hotline-f8`. **`arch-repair` has
  since been retired** on Bogdan's instruction ("Arch repair should die. the
  laptop is dead"). Its own handoff is preserved at
  `/home/bodas/data/arch-repair-handoff.md` — note it covers two different
  machines: the dead HP, and the new `arch` laptop it went on to set up.

---

## 8. One thing worth keeping

The through-line of this whole session was the same failure wearing different
clothes: **a field read as a signal without testing what it actually indicates.**
The `hitchy` verdict, `ZSHRC_OK`, the backgrounded recorder, `element.exists`.
Each looked like a green check and each was measuring something other than the
thing it named. The metric now self-tests, the control gives it a baseline, the
drive prints its tree, and the shell check uses a pty — but the habit is what
matters, not the four fixes.
