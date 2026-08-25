# hotline-ios — narrative log

Append-only. What was tried, what failed, why. Newest at the bottom.

---

## 2026-08-25 — session start (agent `hotline-ios`)

Picked up from `SPEC.md`, written by `hotline-80` from a provenance-verified
instruction of Bogdan's. Declared in the registry as `hotline-ios`, channel
`#agent-hotline-ios`.

### Reading done first

- `SPEC.md` in full.
- `/home/bodas/data/hotline/PLAN.md` (399 lines) and `handoff.md` (399 lines).
  Skipped the 2616-line `PROGRESS.md` — the handoff supersedes it.

What that establishes: **hotline is finished, not in progress.** Phases 0-5 all
done, 398 tests, ruff+mypy clean, pushed through `70b83b8`. There is a working
router with three modes (fresh subprocess / cc-socks inject into a live session /
named systemd agent), a working Discord voice path measured at 0.2-0.36 s per
utterance on the 4060, a working iPhone Shortcut text path, and a pager. The iOS
app replaces exactly one thing: the escalating `@mention` that stands in for a
ring. Everything under it stays.

The one design line from `PLAN.md` that this project has to honour is §2's:
*one router, many transports.* An iOS call is a **new transport adapter**, not a
second hotline. `PLAN.md` §10 explicitly ruled out a real ring — "on iPhone, only
a PSTN call rings unconditionally, and you said no money". That ruling is what
`SPEC.md` §2 is reopening, and it is now a money question in front of Bogdan.

### Local recon (things a research agent cannot see)

Ran on the box, 2026-08-25.

**Toolchain — confirms SPEC §3 and corrects it in one place.**

| tool | state |
|---|---|
| `swift` `swiftc` `xtool` `xcodebuild` `ldid` `zsign` | absent |
| `ideviceinstaller` `ios-deploy` | absent |
| `clang` `lld` `llvm-ar` `cmake` `ninja` | **absent** — not noted in SPEC, and a Swift build needs them |
| `cargo` `go` `docker` `podman` | absent |
| `node` | **PRESENT** — v24.19.0 via nvm at `~/.nvm/versions/node/v24.19.0/bin/node`. SPEC and CLAUDE.md both say node is absent. It is not. |
| `uv` `python3` (3.14) `unzip` `bsdtar` | present |
| `idevice_id` `idevicepair` `iproxy` | present (libimobiledevice 1.4.0, libusbmuxd 2.1.1, usbmuxd 1.1.1) |

**usbmuxd is `inactive` and `static`** (socket-activated). `idevice_id -l` and
`-n` both return `ERROR: Unable to retrieve device list!`, and `lsusb` shows no
Apple device. `/var/lib/lockdown/` does not exist, so **the phone has never been
paired with this machine.** Initial pairing requires a physical USB connection
and a tap on "Trust This Computer" on the phone. That is a physical task for
Bogdan and it is on the critical path for any sideload that goes over USB —
logged now rather than discovered later.

**Phone is up over Tailscale**: `100.108.255.28`, name `phone`, iOS, idle,
2/2 ping, RTT 91-516 ms (mobile radio, so jittery — matters for the audio
transport design, see below).

### The disk constraint is not a constraint

`SPEC.md` §3 calls disk the make-or-break: 7.7 GB free on `/`, 89% used, and the
5.1 GB pacman cache is not to be touched because it is this box's only package
rollback.

All true, and irrelevant, because `lsblk -f` shows:

```
/dev/nvme0n1p3  ntfs  879G  289G used  591G AVAILABLE  →  /mnt/windows
```

Mounted `rw,noatime,uid=1000,gid=954,...` — i.e. **already writable as `bodas`**,
verified by touching a file there. 591 GB free next to the 7.7 GB everyone has
been budgeting against.

NTFS cannot host a Swift toolchain directly: no symlinks, no executable bit,
case-insensitive. The standard move around that is a **sparse ext4 image file on
the NTFS volume, loop-mounted**. `/dev/loop-control` exists, the `loop` module
just needs a `modprobe`, and `%wheel NOPASSWD: ALL` is already in place so the
mount needs no interaction. It is also trivially reversible: it is one file, and
deleting it reclaims everything.

That takes the toolchain disk budget from "7.7 GB and do not touch the cache" to
"as much as you want". It does not by itself make an iOS build work — that is
still the open question — but it removes the reason it was expected to fail.

### Four research tracks launched in parallel (sonnet)

1. **The entitlement question (SPEC §2)** — does free/personal-team provisioning
   grant `aps-environment` / PushKit, and what is the real ceiling of outcome B.
   Also tasked with the outcome-C question that actually decides C: Linphone's
   push goes through linphone.org's flexisip gateway, so does pointing it at a
   self-hosted SIP domain require self-hosting flexisip, and does *that* need an
   Apple push certificate — which would collapse C back into the same $99.
2. **Linux iOS build toolchain (SPEC §7)** — `xtool` first, then Swift SDKs,
   darling, theos, ldid/zsign, AltServer-Linux, GitHub Actions macOS runners.
   Told the real disk number is now 591 GB, not 7.7.
3. **Sideloading from Linux (SPEC §6)** — AltStore/SideStore/anisette, pairing
   files, `ideviceinstaller` on modern iOS, the 7-day re-sign automation, and
   what genuinely needs Bogdan's hands.
4. **hotline integration map (SPEC §4)** — exact seams in `voice.py`,
   `audio.py`, `router.py`, `pool.py`, `agents.py`, `httpd.py`, and what is real
   today versus aspirational.

### The guard blocked the loop-image plan, and I left it blocked

`mkfs.ext4` on a **regular file** was refused by hotline's own `PreToolUse`
denylist:

```
hotline guard: refusing creating a filesystem (destroys the target device).
This is blocked unconditionally because it cannot be undone. If you genuinely
meant it, a human has to run it at the keyboard.
```

Read `hotline/src/hotline/guard.py` before reacting. `mkfs` is in `_ALWAYS` —
"catastrophic no matter what arguments" — and the module docstring is explicit
that a denylist people route around protects nothing, and that routing around it
is the exact habit it exists to prevent. It is right about that, so I did not
rename the binary, wrap it, or ask a peer with sys-admin to run it for me. The
last of those would be laundering.

**Finding for `hotline-80`, not acted on:** the guard cannot distinguish
`mkfs.ext4 /dev/nvme0n1p4` from `mkfs.ext4 ./disk.img`. The first destroys a
disk; the second creates a file. That is a real false positive on a legitimate
and completely reversible operation. `_DEVICE` already exists in that module and
is used for `dd`/`shred`; the same test would fit here. **Not my call and not my
file** — flagging it, not changing it.

### Space, without NTFS and without the guard

The loop image was never the only answer. `du` on `/`:

| path | size | verdict |
|---|---|---|
| `~/.cache/uv` | **7.7 G** | pure cache. uv hardlinks into venvs, so clearing it does not break the existing hotline venv — the inodes are refcounted. Re-downloads on next install. |
| `~/.cache/yay` | **1.4 G** | AUR build cache, rebuildable |
| `~/.cache/google-chrome` | 636 M | browser cache |
| `/var/cache/pacman/pkg` | 5.1 G | **DO NOT TOUCH** — this box's only package rollback (root is ext4, no snapshotting) |
| `/timeshift` | 15 G | the 2026-08-24 snapshot. Do not touch. |
| `/opt/cuda` | 4.8 G | one of data-f3's two unanswered questions to Bogdan. Not mine to answer. |
| `/swapfile` | 8.1 G | zram is also configured. Reclaimable in principle, but a live system change for disk that is not yet needed. |

So: **7.7 GB free today, ~9.7 GB more from caches alone, no permission questions
and no guard involved.** That is ~17 GB, which is very likely enough — the real
number is what track 2 is measuring. Not clearing anything until there is a
requirement to clear it for; deleting caches speculatively is just churn.

The 591 GB on `/mnt/windows` stays as the escape hatch if the toolchain turns out
to want more than 17 GB. It costs one `mkfs.ext4` on a file, run by Bogdan at the
keyboard, and it is one `rm` to undo.

## The build attempt — how far this Arch box actually gets

Run 2026-08-25. **Result: everything works except the one thing that needs
Bogdan's Apple ID.** Recorded in full because the negative half is the useful
half.

### Setup

`/mnt/windows/hotline-ios-build.img`, ext4, loop-mounted at `/mnt/iosbuild`.
Verified before trusting it: symlinks, the executable bit, and **hardlinks** —
the last because xtool's extractor explicitly depends on hardlinks between files
inside and outside the wanted set, which is why NTFS cannot host this directly.

**I sized that image wrong and it mattered.** I created it at 120 GB assuming
`truncate` would give a sparse file. ntfs3 did not — `du` reported 120 G
apparent *and* 120 G actual, and `/mnt/windows` dropped from 591 G to 466 G. My
own command printed both numbers and I read past them. `hotline-80` caught it
and Bogdan noticed the space disappear and asked what was creating a drive on
his Windows partition, which is a completely fair thing to be alarmed by.

Corrected to 30 GB: `e2fsck -fp` → `resize2fs 30G` → `truncate -s 30G`, in that
order, unmounted, with the 1.07 GB download parked on plain NTFS first so it did
not have to be fetched twice. **ext4 grows online but only shrinks offline**,
which is the actual argument for sizing small now: growing later is free and
needs no downtime, so there was never a reason to pre-allocate for a worst case
that is currently unreachable anyway.

### What works, verified by running it

| step | result |
|---|---|
| Swift 6.3.3 (`ubuntu24.04` build) on Arch | **works** — `swift --version` clean |
| `swiftc hello.swift && ./hello` | **works** — printed `swift on arch works` |
| xtool 1.17.0 AppImage | **works** — `xtool --version` clean |
| `xtool new HotlineCall --skip-setup` | **works** — full SwiftUI project scaffolded |
| `xtool dev build` reaching SwiftPM planning | **works** |
| The Darwin iOS SDK | **BLOCKED** |

Two Arch-vs-Ubuntu ABI gaps had to be solved on the way, and both were solved
**without installing anything system-wide** — everything lives in a private
`shim/` directory on `LD_LIBRARY_PATH`, and `rm -rf /mnt/iosbuild` undoes all of
it:

- `libncurses.so.6` — Arch ships only the wide build (`libncursesw.so.6`).
  Symlinked, which is fine for `swift`/`swift-package`. It is *not* enough for
  `lldb`, which wants versioned symbols the wide build does not export; the
  debugger is therefore not working and is not on the critical path.
- `libxml2.so.2` and `libicu*.so.74` — Arch is on libxml2 soname **16** and ICU
  **76**. Those are major soname bumps, so symlinking would have produced a
  crash later instead of an error now. Fetched the real Ubuntu 24.04 `.deb`s
  from `archive.ubuntu.com` and extracted just the `.so` files. Replicating what
  the package manager would have done, at a lower level, rather than forcing it.

### The blocker, exactly

```
$ xtool dev build
error: No valid Swift SDK bundles found at /home/bodas/.swiftpm/swift-sdks.
$ xtool sdk status
Not installed
$ xtool sdk install --help
USAGE: xtool sdk install <path>
ARGUMENTS:
  <path>   Path to Xcode.xip or Xcode.app
```

There is no download-it-for-you path and no third-party source. From xtool's own
`Installation-Linux.md`:

> Download **Xcode 26** from […]. The URL above requires authentication, so make
> sure to visit it in your browser rather than running `curl`. You'll be asked to
> log in with your Apple ID and accept the license agreement.

`xtool auth` is gated the same way — even `xtool new` prompts for an Apple ID
login unless given `--skip-setup`, because it registers a bundle id with Apple
Developer Services.

Checked for a way around it and did not find an honest one. `theos/sdks` hosts
extracted iOS SDKs publicly, but the newest is **iPhoneOS16.5** and it was last
pushed 2024-11-23 — far too old for an iOS 26 device, and it is not a Swift SDK
bundle in the form xtool wants. Recorded as investigated and rejected on the
facts, not on principle.

### So the two ways forward, both needing him

1. **He downloads `Xcode.xip`** (Apple ID, browser, ~13 GB) and I run
   `xtool sdk install` locally. Note the extraction spike: xtool unpacks the
   *entire* Xcode.app — every platform's SDK, not just iOS — before filtering.
   Real users failed at 15 GB free and one at 80 GB. The image would need to
   grow first, which is now a one-line online `resize2fs`.
2. **A GitHub Actions macOS runner**, where Xcode is already installed, so
   `xtool sdk build /Applications/Xcode.app` needs no Apple ID and no 13 GB
   download at all. Copy back only the filtered bundle.
   **Blocked on two things of his:** `gh` is authenticated as
   `BogdanStamenovic` but its token scopes are
   `admin:public_key, gist, read:org, repo` — **no `workflow` scope**, so
   pushing a `.github/workflows/` file will be rejected and it needs
   `gh auth refresh -s workflow`. And macOS runner minutes are unmetered only
   for **public** repos, which is his call every time.

Neither is a dead end. Both are one small human action. **What is settled is
that nothing else about this box stops an iOS app being built here** — which was
the question, and the answer is better than expected.

## The daemon, and four bugs found by running it

`hotline-iosd` is the service `hotline-call` talks to. It runs **beside**
`hotlined`, not inside it, for three reasons in order of weight: `hotlined`
carries the Discord bridge and Shortcut path that this degrades *to*, and
putting the experimental ringer in the same process as its own safety net loses
both at once; hotline's `Transcriber`/`Speaker` `load()`/`unload()` are not
reference-counted, so a Discord call hanging up would unload a model out from
under a live phone call; and `HotlineBot.call` is a single-slot attribute that
refuses a second join.

It imports hotline rather than duplicating it — `PYTHONPATH` carries both
`src` trees and it runs in hotline's existing venv, so the ~2 GB of ML
dependencies exist once. Nothing was installed into hotline's venv.

**Four things were wrong, and all four were found by executing it rather than
reading it.** Recording them because three are the kind that look fine in review:

1. **A TTS failure destroyed the whole call.** A `Service` with no speaker
   turned a perfectly good connected call into an HTTP 500. Synthesis has many
   runtime ways to fail — missing Piper voice, VRAM pressure — and none of them
   are a reason to drop a call. He is on the line; he can say "hello?". `say()`
   now logs, emits an error event, and continues in silence.
2. **A call nobody hung up blocked forever.** `place()` awaited the call with no
   ceiling, so a transport that never closes its own stream hung the HTTP
   request indefinitely. There is now a hard `timeout` on the whole call,
   separate from the ring timeout, which ends the call rather than leaking it
   and the request together.
3. **Query strings cannot reach a handler at all.** hotline's `httpd` does
   `path = target.split("?", 1)[0]` and keeps nothing, and routes on exact path
   strings — so neither `?since=41` nor `/events/<id>/<since>` was available.
   The event feed moved to POST with the cursor in the body. That is a
   constraint discovered by running it, not a REST preference: the alternative
   was forking a server Bogdan has already read, to carry two integers.
4. **The last failing test was the code being right.** Once it ran in hotline's
   venv the *real* silero VAD was in the loop, and it correctly refused to hear
   speech in a synthetic tone. A daemon-wiring test that fought that would have
   been testing silero. The segmenter is now injectable — which is also
   genuinely useful, since transports differ in sample rate.

43 tests, 2.2 s.

## A citation I hardened, and the measurement that corrected it

`ConfirmedRing` was justified in its own docstring with an Apple Developer
Forums thread (756941) in which an Apple engineer supposedly answered "100%, no"
to whether a packet tunnel provider keeps running while the phone is locked.

**I did not verify that quote.** It reached me from `data-89`, I wrote it into
the source tree and a commit message as a stated platform fact, and `hotline-80`
then tried to fetch it: the page serves a JavaScript shell with none of the
quoted terms present, and the forums API 404s for the thread. `data-89` checked
too and could not confirm it either; its own research agent had reported it as
"VERIFIED, fetched in full". So the claim gained confidence at every hop and was
never true at any of them. That is the laundering shape, and I was the hop that
put it in the code.

Then `data-89` measured his actual phone instead of arguing about the general
case, and **the strong claim is simply wrong**:

```
tailscale ping, phone locked and idle:  20/20 answered, 0% loss
peer map sampled every 30s for 20 min:  14/14 present, Online=True
```

The tunnel delivers to his locked phone. What survives is weaker and checkable:
a Tailscale contributor on `tailscale/tailscale#17575` describing a **5-10 s**
wait while iOS starts the VPN from an on-demand rule.

**The mechanism did not change and should not have.** Failing closed is correct
whether the tunnel is categorically suspended or merely unreliable — in both
worlds, placing a call is not evidence that it rang. What changed is the
sentence justifying it, in `watch.py` and `ARCHITECTURE.md`, and both now record
the correction rather than quietly showing the better source. A good mechanism
resting on a quote that evaporates when someone checks is how a sound design
gets thrown out with its bad citation.

Two process notes for whoever is next:

- **I killed my own shell twice with `pkill -f <pattern>`** where the pattern
  matched the shell command containing it. Exit 144, no damage, but it looks
  like a crash. Don't `pkill` on a string that appears in your own command line.
- The suite was silently taking 45 s because `ring()`'s 45 s default timeout
  leaked into a test asserting an immediate distinction. hotline's handoff says
  to suspect the tests when the suite is slow. It was right.

## The GitHub Actions route, and the app

### Authorisation: a relay that failed to verify, and what happened next

`data-89` relayed that Bogdan had authorised both the `workflow` scope and a
throwaway public repo, quoting him and citing a message id. **I could not verify
it** — `hotline --provenance` returned "Discord has no such message" — so I did
not act on it.

I did not read that as anything being wrong; a wrong `channel_id` was far more
likely than a bad relay, and it was. But a failed check is a failed check.
Creating a public repo under his account is an outward action, and a peer cannot
authorise one however plausible it is — `data-89`'s message carries a
`kind=agent` header that says exactly that about itself.

So: kept building everything that did not depend on it, staged the repo locally
down to the last file, and asked `hotline-80` for the receipt. It found the
message in `#general` rather than either agent's channel and sent the record. I
verified it myself rather than on its say-so:

```
VERIFIED: posted by 1329897799336071311 in channel 1541467532375101565
> You may create a trhoway public repo. So thats the way
```

The other half was corroborated by the state of the world instead of a relay:
`gh auth status` now lists the `workflow` scope, and only he could have finished
that device-code flow.

`hotline-80` noted this as the `--warrant` design working end to end for the
first time — a relayed authorisation, checked by the recipient, failing, and
resulting in a request for the receipt rather than either proceeding on
plausibility or stalling silently.

### The repo

`BogdanStamenovic/darwin-sdk-build`, public, **exactly two files** — verified
against the pushed tree, not against my intent:

```
blob .github/workflows/build-darwin-sdk.yml
blob README.md
```

"Throwaway" is his adjective, so it gets deleted once the SDK artifact is
retrieved. Public only so macOS runner minutes are unmetered; it carries no
tailnet addressing, no agent tooling, no hotline source, no credentials.

It runs `xtool sdk build /Applications/Xcode.app` on a `macos-15` runner, where
Xcode is already installed — so **the 13 GB `Xcode.xip` download against his
Apple ID is not needed at all**, and neither is the local extraction spike that
made this impossible on his box. It also runs `du -sh` on the filtered bundle,
because nobody has published that number and every figure so far has been an
estimate.

### The app

Written now rather than after the B-vs-C decision, because it is B's long pole
and C is currently blocked on him installing Linphone, which he says he cannot
do right now.

`CallCenter.swift` is the file that matters. It **never instantiates a
`PKPushRegistry`**, deliberately: `CXProvider.reportNewIncomingCall` takes no
entitlement, which is the whole reason this works on a free Apple ID, while
`aps-environment` is not granted to free provisioning. The iOS 13 rule that a
VoIP push must be answered with a call report binds apps that *accept* such a
push, so it never applies. Its docstring states the honest limit in the same
breath: **a push wakes a dead process and this cannot**, so a force-quit or a
reboot means nothing rings — which is precisely what `ConfirmedRing` exists to
detect on the server.

Writing both halves immediately found a gap: the app called `/api/v1/hangup`
and the server had no such route.

54 tests.

## Outcome B's transport, and an ordering trap worth writing down

### `ring/local.py` — ring his own app, nothing leaving the tailnet

The server counterpart to the app. The only design where "everything over
Tailscale" is literally true including the doorbell: no push, no APNs, no third
party. The app holds a long-poll open, the server writes a ring down it, the app
calls `reportNewIncomingCall` itself.

**Presence is the long-poll, not a flag.** There is deliberately only one fact
about whether the app is alive, because a flag plus a heartbeat can disagree and
then something has to decide which is lying. While a poll is open the device is
present; 45 s without one and it is gone.

**The acknowledgement is the proof, and it is separate from presence.** The case
that motivates it: the process is alive enough to poll but iOS refused to show
the call — Do Not Disturb, already in a call, or the system simply said no.
Presence would report success there and the call would vanish. So the app must
say it put a call on screen, and no ack inside the window is `CallUnreachable`,
which the chain turns into Linphone or a page.

`rings_when_closed` is a **property returning False**, not a class attribute, so
nobody can set it True after watching it work once with the app in the
foreground. It cannot wake a process that is not running; that is a fact, not a
setting.

An absent app fails *before* ringing rather than after a 45 s ring-out — which
is what lets the chain reach Linphone while he is still near the phone. All four
silent-death paths (force-quit, reboot, expired certificate, iOS reclaiming the
process) look identical from here: nothing is polling.

71 tests.

### The ordering trap — do not delete the repo first

`hotline-80` caught this and it would have cost a 90-minute build.

The plan said "delete the throwaway repo once the artifact is retrieved", and
the workflow sets `retention-days: 5`. **GitHub artifacts live under the
repository, not independently — deleting the repo destroys the artifact with
it.** The diligence and the mistake point the same direction, which is exactly
why it needs to be written down rather than remembered.

**Strict order:**

1. run completes
2. download the tarball to `/mnt/iosbuild`
3. verify it unpacks *and* `xtool sdk status` sees it
4. **only then** delete `BogdanStamenovic/darwin-sdk-build`

### The SIP probe stays up

Asked whether Bogdan being unable to install Linphone was temporary or
structural, because an open SIP port on the tailnet for an experiment that will
never fire is not something to leave and forget. Verified answer: temporary —
"my cellular right now is shit so im waiting till i get home". So C is still
actionable, the probe stays running, and the test happens when he is on wifi.

## He changed the design, twice, and both times it cost almost nothing

### The decision — Telegram rings, his app talks (verified, 16:59)

> Okay so this is the idea: make your own app for delegation talking excetera
> which i will sideload every week.
>
> Telegram for the ring. And we can fully scrap the talking voice rout. Thats
> bassically a gimic

He spotted what all three agents had missed: **every option costed for him
assumed the thing that rings is the thing you talk through.** B made one app do
both and paid for it with a keepalive that dies when someone phones him; C took
a stranger's app to get the ring and inherited its interface. Decoupling them
dissolved, at once: CallKit, the local-ring question, the audio-session
keepalive, the push entitlement, the reboot gap, the entire SIP/Belledonne
dependency, and the audio transport.

Then at 17:10, also verified: **"Okay we will do both"** — Telegram *and*
Linphone, because they fail for unrelated reasons.

### What the swappable transport actually bought

Four doorbells in one day — paid Apple, own-app-over-socket, stock SIP,
Telegram — plus a late "both". **Nothing above `RingTransport` was rewritten
once**, and "both" turned out to be `HOTLINE_IOS_RING=telegram,sip`: a
configuration, not a fork. That was the one design decision made before anything
was known, and it is the one that paid.

`RingTransport` also *lost* something: it used to return a `MediaStream`,
because carrying audio only made sense while the ringer was the talker. It now
rings and returns nothing.

### Parking beat deleting, and it was not my call

I started deleting the SIP and audio work when the design changed. `hotline-80`
stopped me: the whole plan rested on Telegram being on his phone, which was
unconfirmed, so C was the branch to return to. **Four hours later he asked for
both**, and it came back in one `git mv` with its tests intact instead of an
archaeology session.

`data-89` put the general principle better than the specific call: it was not
foresight about Telegram, it was that **deleting is irreversible and deferring
costs nothing**, so the asymmetry decides it without predicting anything.

### I paged him by accident, in a test

**The worst thing I did today.** Testing `hotline-call` against a live daemon, a
stale invocation from a minute earlier was still running, hit its timeout, and
did exactly what it is designed to do: **fell back to the real Discord pager**.
It DM'd Bogdan asking *"may I spend money on a UI agency"*. He answered "Nope".

Two failures, both mine and neither the code's:

1. **The test question was indistinguishable from a real one** — and it was in
   the single category that requires his approval, which is the worst possible
   one to fake. A test page should be unmistakably a test.
2. **I did not check for a stale process before starting another.** Each Bash
   call is a fresh shell, so `kill %1` referred to nothing, and the previous
   daemon and CLI were both still alive. That is also why the first attempt's
   routes appeared missing: an old daemon still held the port and the new one
   never bound.

Told him immediately and plainly rather than letting it sit. Nothing that can
page him is running now, checked with `ps` rather than assumed. Tests from here
use the loopback doorbell, which cannot reach Discord.

The fallback itself behaved correctly and is the feature: adopting
`hotline-call` is never worse than staying on `hotline-page`. It was aimed
badly, not wrong.

### The round trip works, end to end, against a real daemon

Verified over real HTTP, not in a test harness:

```
agent runs hotline-call, blocks
  -> daemon writes the question into a conversation
  -> rings (loopback)
  -> app lists what is waiting:
       {"asked": "the ios build: may I spend money on a UI agency",
        "waiting": true}
  -> he types a reply
  -> blocked agent gets "up to 500 euro" on stdout, exit 0, in 3 seconds
```

`/api/v1/agents` was checked against the **real** registry, not a stub: four
live sessions, busy flags correct, and one that never declared itself listed
under its derived name.

**Running it found a gap nothing else would have.** A ring opens a conversation
on the *server* — the phone was never involved and has no id for it — so the
question sat there and the app could not find it. `/api/v1/conversations` and
`/api/v1/reply` exist because of that.

Also of note: the daemon now imports **no ML dependencies at all**. The whole
suite runs in one venv, no GPU, no models — a consequence of the voice route
going, not a goal.

54 tests, ~2 s.

## State at the end of this stretch

**54 tests, ruff clean, mypy clean, one venv, no ML dependencies.**

`mypy` found a real packaging bug that runtime never would have:
`src/hotline_ios/` had **no `__init__.py`** and had been working purely as an
implicit namespace package the whole day.

The broad `except Exception` clauses that are deliberate now say why on the
`noqa`, matching hotline's practice. One of them was genuinely sloppy rather
than deliberate: `ConfirmedRing` swallowed a cancelled transport's own exception
with a bare `pass`, which is how a transport bug stays invisible.

### The one place my chosen evidence is not evidence

`data-89` found it, and it goes in the code rather than in a chat message
because whoever hits it will be reading the code.

`TelegramTransport` treats "Telegram accepted the call request" as proof the
phone is alerting — that is what `ConfirmedRing` waits on. **If his
Settings → Privacy → Calls is "Nobody", Telegram accepts the request and never
rings him**, and nothing in the response distinguishes that from success. So the
confirmation would report a ring that did not happen, which is precisely the
failure `ConfirmedRing` exists to prevent.

It cannot be closed from inside the transport. It has to be checked on his phone
once.

### What my accidental page cost, and what it bought

`hotline-80` found that the retraction had a hole *its own module* created: I
retracted in my channel, but his "Nope" is in `#general` and carries no
`message_reference`. So a verified, quotable, provenance-checkable message from
him reading "Nope" was sitting there **attached to nothing**, on the subject of
spending money — and `hotline --provenance` would confirm it verbatim with no
indication that it answered a question nobody asked.

Its fix (commit `8dd8c14`): a verdict now reports context, quoting the
referenced message when there is one and warning explicitly when a short message
is not a reply to anything. Its own summary of the underlying defect is the
useful sentence: **a reply's meaning lives in its question, and the question was
never part of the receipt.**

So the mistake was mine and the defect was older than the mistake.

### Two things worth not re-learning

- **Each Bash call here is a fresh shell, so `kill %1` refers to nothing.** Job
  control does not survive between tool calls. That is what left a stale daemon
  holding the port (making new routes look missing) and a stale `hotline-call`
  alive long enough to page him.
- **`pkill -f <pattern>` matches the shell command containing the pattern**, so
  it kills its own invocation. Exit 144, twice, before I stopped using it.

## Partial verification of the app, without the SDK

The Darwin SDK is still building, but the Swift compiler on this box is real, so
some of the app can be checked now rather than after.

```
ContentView.swift      syntax OK
HotlineCallApp.swift   syntax OK
Link.swift             syntax OK
Model.swift            syntax OK
Store.swift            syntax OK
```

All five **parse** cleanly (`swiftc -parse`). And `Model.swift`, which imports
only Foundation, **fully type-checks on Linux** — not just parses. `Link.swift`
type-checks up to `import OSLog`, which is Darwin-only and is exactly the error
it should give.

That is worth stating precisely, because it is easy to oversell: **this proves
there are no syntax errors and that the toolchain works. It does not prove the
app compiles**, because everything touching SwiftUI, CallKit or OSLog needs the
SDK that is still building. Typos are ruled out; type errors against Apple's
frameworks are not.

## The second doorbell — written rather than installed

`data-89` caught that `sip.py` did not exist while `build_transport`'s own
docstring used `HOTLINE_IOS_RING=telegram,sip` as the example of his
"we will do both" — and `sip` was exactly the value it refused. He was about to
send a SIP address with nowhere to put it.

**It needs no `baresip`, and therefore no system package he has not approved.**
That is possible only because it never carries audio:

```
REGISTER to sip.linphone.org  ->  INVITE his account  ->  180 Ringing  ->  CANCEL
```

His phone rings on the INVITE, linphone.org's own push wakes the app, he hangs
up on it and opens ours. No SDP worth the name, no RTP, no codec. What is left
is a text protocol and one MD5 digest.

### Its evidence is the best in the project

`ConfirmedRing` needs proof the phone is alerting.

- Telegram gives "the server accepted the request" — an **inference**, and the
  one `data-89` correctly identified as possibly not evidence at all.
- SIP gives **`180 Ringing`**: the far end saying, in the protocol's own words,
  that it is ringing.

`183 Session Progress` counts too, because some proxies send it instead and
treating that as silence would report a working doorbell as broken. And silence
claims nothing — **no 180 means `CallUnreachable`**, even though the INVITE was
sent and nothing errored. That property has a test named after it, because it is
what makes the transport safe inside `ConfirmedRing`.

### Verified, precisely

- **The digest reproduces RFC 2617's own worked example byte for byte.** If that
  ever breaks, authentication breaks with it and the error would be far less
  obvious.
- **The whole exchange against a real SIP server over real UDP** — real
  datagrams, real 401 challenge, real authenticated re-REGISTER, real INVITE,
  real CANCEL. Nothing mocked between the transport and the socket.
- Declined (486), not-found (404), bad credentials (403) and silence all stay
  distinguishable, so the chain falls through on exactly the right one.

**Not verified: that `sip.linphone.org` behaves this way.** That needs his
account. TLS is implemented and unverified; UDP is the default because it is the
one that could be smoke-tested without credentials.

One real bug the tests found: the response loop decremented a counter by a fixed
5 s per read regardless of how long the read took, so a `180` followed
immediately by a `200` ended the loop before the `200` was ever read.

**68 tests, ruff clean, mypy clean.**

### The biggest unknown in `sip.py`, removed without an account

`sip.linphone.org` answers an **unauthenticated** REGISTER with a 401 challenge,
which needs no credentials at all to elicit. So this was testable now rather
than at 20:30 with him waiting:

```
sip.linphone.org -> 176.31.149.179
udp:5060         -> SIP/2.0 401
challenge        -> realm=sip.linphone.org  nonce=...  opaque=+GNywA==
                    algorithm=MD5  qop=auth
```

Three things that were open are now closed:

1. **The host is reachable from archserver over UDP 5060.** That was the reason
   TLS was being held in reserve; UDP works.
2. **They speak the protocol as expected**, and answer promptly.
3. **`parse_challenge` handles their real header**, including `opaque` — which
   they send, many servers do not, and which must be echoed back verbatim or the
   authenticated REGISTER is rejected. That failure presents as "it just does
   not ring", with no useful error.

Their exact challenge is now a test fixture, alongside one asserting the
`Authorization` header echoes `opaque` and carries `qop`/`nc`/`cnonce`. Kept as
a fixture rather than a live call so the suite stays offline.

**Still unverified: everything after authentication succeeds.** That needs an
account, and the INVITE reaching his handset needs his phone.

**70 tests.**

## The SDK build failed, and the failure was mine twice over

**Attempt 1 ran for 90 minutes 15 seconds, produced zero output, and was killed
by its own `timeout-minutes: 90`.** Not a crash, not a GitHub problem — my
workflow's timeout, reached.

Reading the completed log rather than guessing gave two faults, both mine:

### 1. I called the wrong subcommand

xtool's own help, which I had already captured hours earlier and did not read
carefully enough:

```
install (default)   Install the Darwin Swift SDK   <path>  Path to Xcode.xip or Xcode.app
build               Build the Darwin SDK from Xcode.xip
```

**`build` takes a `.xip`. `install` takes a `.xip` *or* an `Xcode.app`.** I ran
`xtool sdk build /Applications/Xcode.app` — the one combination that is not
offered. The `|| xtool sdk install` fallback never ran, because `build` never
exited.

### 2. There was no instrumentation, so 90 minutes of silence meant nothing

The step emitted exactly one line in an hour and a half: the command itself.
That makes "extracting something enormous" and "hung on the first syscall"
indistinguishable, and I had no way to tell which. **A long-running step with no
progress output is a workflow I wrote badly**, independent of the wrong
subcommand.

### Also wrong, and worth noting

`/Applications/Xcode.app` on the runner points at **16.4**. xtool's docs say
Xcode 26 — and the runner carries everything from 16.0 to **26.3**. So even had
the subcommand been right, it would have built an SDK from the wrong Xcode.

### Attempt 2

- `xtool sdk install`, explicitly against `/Applications/Xcode_26.3.app`
- a watcher printing elapsed time, free disk and output size every 60 s
- `script(1)` to give xtool a pty, since printing nothing when piped is the
  usual cause of exactly that silence
- `timeout-minutes: 180`
- `sdk install --help` echoed into the log first, so the next person does not
  have to trust my reading of it

If it fails again, it will now say *how*.

### Attempts 2, 3 and 4 — the cause is probably an interactive prompt

**Attempt 2 hung in the `Install xtool` step**, on an xtool invocation that
should take milliseconds. That is the informative part. The only change to that
step was two extra xtool calls — so the hang moved when I moved the calls, which
points at xtool itself rather than at the SDK work.

And there is a local reproduction. Running `xtool new` on this box earlier:

```
Select login mode
0: API Key (requires paid Apple Developer Program membership)
1: Password (works with any Apple ID but uses private APIs)
Choice (0-1): Error: I/O on closed channel
```

It only *errored* here because the channel was already closed. **On a runner
with a pty it would sit and wait.** That is a much better explanation of
attempt 1's ninety silent minutes than "extracting something enormous" — an
extraction would have produced *some* output, and it produced exactly none.

So attempt 3 closed stdin on every xtool call, and dropped `script(1)` — giving
it a pty was actively counterproductive, since a pty is what lets a prompt wait
rather than fail.

**Attempt 3 then failed in ten seconds on `timeout: command not found`.** That
is GNU coreutils; macOS does not ship it. Entirely my bug and unrelated to the
hypothesis — but a ten-second failure naming its own cause, instead of ninety
minutes teaching nothing, is exactly the argument for having built the
instrumentation. It caught my mistake as readily as xtool's.

Attempt 4 running without `timeout`.

**None of this is good news yet, and it should not be reported as any.** The
stdin theory is well-supported and still a theory. Nothing has produced an SDK.
The app has never been compiled against one. What has actually improved is that
failures now cost seconds and name themselves.

### The Xcode symlink, worth keeping regardless

`/Applications/Xcode.app` on the runner points at whatever the image defaults
to — **16.4**, while the same image carries up to **26.3** and xtool's docs ask
for Xcode 26. That will change silently between runner image releases. The
workflow now pins `Xcode_26.3.app` explicitly and exposes it as a
`workflow_dispatch` input, so the next surprise is a one-word change rather than
a rediscovery.

### His SIP address arrived, and the calling account stopped at a captcha

Verified from Discord myself (msg `1541877810174369853`):

> Okay so i setup linphone the sip is sip:b0g13a@sip.linphone.org

In `.env` (mode 600, gitignored, confirmed with `git check-ignore`).

`data-89` took account creation as far as it goes and **stopped at a live
hCaptcha** — real sitekey, real widget, not the click-through it resembles. That
is the right stop: CLAUDE.md scopes the improvisation mandate to engineering
dead ends, explicitly not to policy ones, and defeating an anti-abuse control is
the second. The cost of stopping is two minutes of a man already at a keyboard.

**A test I ran that proved nothing, and the control is why I know that.** I sent
an `OPTIONS` to his address and to a deliberately fake one:

```
sip:b0g13a@sip.linphone.org                    -> SIP/2.0 407
sip:definitely-not-a-real-user-xyz@...         -> SIP/2.0 407
```

Identical. linphone.org discloses nothing before authentication. Without the
control row I might have read "407 for his address" as meaning something — the
same mistake shape as the Apple capabilities table earlier, where an empty cell
only became decidable against a row known to be populated.

### Escalating approach class, not attempt count

Four attempts at xtool-on-macOS is still **one idea**, and CLAUDE.md is explicit
that the move is to change category rather than keep varying the same one. So
the next approach is written down before it is needed.

Reading xtool's own `SDKBuilder.swift` shows exactly what a Darwin SDK is made
of, which means it can be assembled without xtool ever running on macOS:

```
Platforms/{iPhoneOS,MacOSX,iPhoneSimulator}.platform/Developer/SDKs/*.sdk
Platforms/*/Developer/Library/{Frameworks,PrivateFrameworks}
Toolchains/.../usr/lib/{swift,clang}
```

**Plan B: let the runner be a file server, not a build machine.** `tar` those
subtrees out of `Xcode_26.3.app`, upload as an artifact, reassemble the
`Xcode.app`-shaped tree on archserver, and run the **Linux** xtool — the one
that demonstrably works here — with `sdk install` against it. macOS xtool never
executes at all.

The cost is transfer size. `iPhoneOS.sdk` alone is likely the only one needed to
build for a device, and dropping `MacOSX` and `iPhoneSimulator` should cut it
several-fold. That is a measurement to take on the runner, not a guess — and the
`du -sh` already in the workflow was put there for exactly this reason.

**Plan C**, if that also fails: build the `.ipa` on the runner outright with
plain `xcodebuild`/SwiftPM and no xtool. That needs the app source in a repo,
which is a decision of his rather than mine — the fallback workflow for it is
written and deliberately unpushed.

## HIS PHONE RANG

2026-08-25, ~20:45. Verified on his actual handset, twice, with his own words:

> Yep i got both calls. Its Perfect.

> It ringed i declined

And from this side, matching: `180 Ringing` → `200 Ok` on the one he answered,
`486` in 4.4 s on the one he declined. Two-sided confirmation, not an inference.

The last of those ran through the **shipped transport reading `.env`** — no
arguments, no monkeypatching — so the thing that rang him is the thing that will
ring him.

### What was actually wrong, in the order it was found

1. **REGISTER worked immediately.** The hand-written digest authenticated
   against `sip.linphone.org` on the first try, which is what the RFC 2617
   fixture bought.
2. **The first INVITE got no response at all over UDP.** Not a 100, not a 407.
3. **Over TLS the same INVITE produced a whole conversation:**
   `407` → auth → `100 Trying` → **`110 Push sent`** → `488 Not acceptable here`.
   `110 Push sent` is linphone.org's gateway confirming it had pushed his phone
   — the mechanism this whole option rests on, observed working.
4. **He saw "a call for a split second" and could not tell it from a
   notification bug.** That is exactly what a `488` *after* a push looks like
   from outside: the push wakes the phone, then the call collapses.
5. **His client requires encrypted media.** Offering `RTP/SAVP` with an SDES
   crypto line, and a real bound port instead of port 9 (discard), made it ring
   properly.

His instinct — *"Call again"* — is what produced the diagnosis. One more ring
turned an ambiguous flicker into a reproducible failure.

### A correction I had to make to myself within minutes

I wrote **"linphone.org silently ignores INVITEs over UDP"** into the docstring
*and* into a message to him, on the evidence of one silent attempt.

**A later run over UDP rang his phone.** That refutes it.

The likelier cause is duller and is a defect here rather than there: **SIP over
UDP requires the client to retransmit an INVITE** (RFC 3261 timer A, 500 ms
doubling), and this does not — so one lost datagram is indistinguishable from a
server that never answers. TLS remains the default, now for a correct reason
(TCP retransmits for us) rather than an invented one.

Same failure shape as the Apple forums quote earlier: a single observation
promoted to a general claim. The difference is that this one was caught by my
own next run rather than by someone else.

### Also fixed, and only reachable once he answered

A `200 OK` is now **ACKed, and the call ended with BYE rather than CANCEL.**
CANCEL after a final response is invalid. Until tonight the code had never
reached a 200, so CANCEL had always been right.

**73 tests, ruff clean, mypy clean.**
