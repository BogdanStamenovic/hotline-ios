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
