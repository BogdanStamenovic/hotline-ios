# Handoff — hotline-ios, 27 August 2026 ~11:00 CEST

Written under a shutdown order, as the last one was. The previous session's
handoff is preserved at `docs/HANDOFF-2026-08-27-0220.md` — **its §6 "Traps" is
still the best thing in this repo and worth reading in full.** Everything else
in it should be read through the corrections below.

Repo `main`, everything pushed. Shutdown is recoverable: WoL is reported
verified, `wakeonlan a8:a1:59:fd:4d:13`.

---

## 1. The one thing that matters

**The app's signing profile expires 2 September 04:16. He is away until
9 September.** He is gone for the entire gap, so unless he re-signs from the
laptop travelling with him, the app stops launching on his phone and stays dead
for a week.

Everything needed for that is built, served and rehearsed. His whole job is one
command on the laptop, phone plugged in and unlocked:

    curl -fsSL http://100.72.2.62:8790/get.sh | bash

He has been told, twice, and it is in the served `README.txt`.
`hotline-profile-watch.timer` will page him daily from 30 August.

**Do not re-derive that date.** The 1 September 22:53 written all over this repo
was wrong — it was seven days from when the *device* was registered, but the
profile's clock starts at *install*. Ask the authority:

    /mnt/iosbuild/toolchain/xtool.AppImage ds profiles list

## 2. Three things the last handoff asserted that are false

Checked, not reasoned about:

1. **"I cannot compile Swift on this box."** The toolchain is here and works.
   Swift 6.2.3 plus the 3.1 GB Darwin SDK on the ext4 loop image at
   `/mnt/iosbuild`, in `/etc/fstab`, mounted. A clean `.ipa` builds in **8.5 s**
   from scratch, 3.4 s incrementally:

       source /mnt/iosbuild/env62.sh
       cd app/HotlineCall && /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa

   `docs/BUILDING.md` documented this the whole time, *including* the trap that
   produced the false claim: `swift` is not on `PATH` until `env62.sh` is
   sourced, so "command not found" reads as "no toolchain". **You are not
   writing blind and you do not need a 13-minute CI round to typecheck.**

2. **"xtool needs a system-wide install, so it needs his yes."** No system-wide
   install exists — it is an AppImage — and it was already on the box at
   `/mnt/iosbuild/toolchain/xtool.AppImage`. The item held overnight for his
   approval was never blocked on him.

3. **The 403 device-limit failure is resolved, not open.** His iPhone 15 Pro is
   registered and `ENABLED` under team `3GAQP72Y5Z`. **Do not act on the
   "second Apple ID" option in `docs/DEVICE-LIMIT.md`** — it is not needed and
   would cost him an account for nothing.

## 3. What this session built

- **`hotline-beam.service`** serves the sideload kit from `/mnt/iosbuild/beam`
  on `100.72.2.62:8790` (tailscale address only, not the LAN).
  **Pull, not push, and that is the design, not a convenience.** I tried to
  `scp` the kit to the laptop and it died mid-transfer: the laptop travels with
  him and drops off the tailnet without warning. A pull runs when his side is
  up, which is the only side that can decide that.
- **`tools/beamd.py`** instead of `python -m http.server`, because that one
  answers a Range request with the *whole file*, so `curl -C -` restarts from
  zero and a 54 MB signer never lands on a link that keeps dropping. Verified:
  a truncated 5 MB `.ipa` resumes through it to a byte-identical md5.
- **`tools/profile-watch.py` + timer** — SPEC §6's expiry warning, which had
  never been built. Queries Apple daily, pages him under 3 days. Both directions
  exercised.
- **The wire tests now run against the live daemon**, and that turned up the
  bug in §4.

## 4. The bug worth remembering

`app/wiretest/run.sh` wrote its history refresh to `fixtures/live-history.json`
while every sibling wrote `today-*`. The `live-*` set is deliberately frozen at
an **older** daemon's shape — it is the only thing proving the app degrades
gracefully when `phases` is absent. So every live run silently overwrote the
evidence, and the degradation checks would have kept passing against
current-shape bytes: **green, and measuring nothing.**

That is the same failure the last handoff's §8 is about, and it had been sitting
in the test harness the whole time. Fixed, plus the current history shape is now
tested at all, which it never was.

The other failure that run surfaced was honest but stale: a check asserted no
event carries `duration_ms`. The daemon now sends it. Absence was a snapshot,
never an invariant — it now asserts that whatever arrives decodes.

**257/257 against the live daemon.**

## 5. Open, and genuinely blocked on him

1. **The re-sign.** §1. Nothing more I can do; the cable and his Apple ID 2FA
   are the wall, and it is the right wall.
2. **`gh repo delete BogdanStamenovic/darwin-sdk-build`** still needs
   `gh auth refresh -h github.com -s delete_repo` from him. Unchanged for three
   handoffs; low value, do not spend a page on it alone.
3. **The decide card's A/B option rows** need a server change — `Waiting`
   (`Wire.swift:351`) carries `asked: String?` and no options array. Inventing
   two would be fiction on the one screen whose job is extracting a real
   decision.
4. **The three header chips** vs the mockup's one pill. Left deliberately: he
   asked for somewhere to retire and delete. His call.
5. **The two-tap-to-open behaviour.** Real on his phone. I flagged it in the
   served README and asked; he has not answered.

## 6. What I could not do, stated plainly

- **Nothing this session has been on his phone**, and nothing can be until he
  runs the command. The build on the device is still 26 Aug 04:16 and has none
  of the conversation-screen redesign.
- **Device-side jank measurement remains undone** and is now impossible until at
  least 9 September — the phone is with him. The CI work settled that the *CI
  measurement* was broken, not that the app is smooth on real hardware. Do not
  let the "at or below the floor" verdict be read as the latter.
- **I never ran the app.** Local builds compile and the wire tests execute real
  app code on Linux, but nothing renders a view outside the macOS simulator.

## 7. Machine state

`hotline-ios`, `hotline-beam`, `hotline-profile-watch.timer`, `hotlined` — all
active and enabled, linger on. `/mnt/iosbuild` mounted. The served `.ipa` is
byte-identical to a clean build of `main` and its published SHA256 verifies over
HTTP.

**If `/mnt/iosbuild` is empty after a boot, the mount is down, not the toolchain
gone.** `findmnt /mnt/iosbuild || sudo systemctl start mnt-iosbuild.mount`.

## 8. One thing worth keeping

The last handoff ended on: *a field read as a signal without testing what it
actually indicates.* Every single thing I found today was that again — "swift:
command not found" read as no toolchain, a device list read as a quota, a
derived date read as the expiry, and a test fixture being overwritten by the
harness meant to protect it. None of them were hard to check. They were just
never checked, because each one already looked like an answer.
