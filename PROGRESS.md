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
