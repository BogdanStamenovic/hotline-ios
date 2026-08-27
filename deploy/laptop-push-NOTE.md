# The kit is on the laptop already — 27 Aug 2026 16:15 CEST

Pushed over scp at his own instruction (Discord 1542536993014288405 +
1542537150975709204: *"push the installer installation on the arch laptop"*,
*"he can do it trough scp"*). This supersedes "pull, not push" **for this
delivery only**: the reason for pull was that his laptop drops off the tailnet,
and the answer to that is not a better transport, it is that the bytes are
already there before he opens the lid.

Landed at `~/hotline` on tailnet host `arch` (100.103.46.118, hostname
`bogdan`) — the same path `get.sh` uses, so the two routes converge and either
one still works.

    HotlineCall.ipa   9892029  OK
    sideload.sh          3781  OK
    xtool.AppImage   53594616  OK

`sha256sum -c SHA256SUMS` passes **on the laptop**, not here. A clean scp exit
is not evidence; the far-end checksum is.

## What the push overwrote

`~/hotline` already held a **truncated 1,044,480-byte `HotlineCall.ipa`** dated
27 Aug 10:23 — the corpse of the earlier scp that died mid-transfer. It was
1/10th of a real `.ipa` and would have been installed as a corrupt app by
anyone who ran `sideload.sh` in that directory. `get.sh` would have healed it
(`curl -C -` resumes); a hand-run `sideload.sh` would not have. Gone now.

## Prerequisites, checked on the laptop rather than assumed

| thing | state |
|---|---|
| `xtool.AppImage --version` | **runs directly**, 1.17.0 — FUSE fine, no `--appimage-extract` fallback needed |
| `usbmuxd` | installed, `inactive`/`static` — normal, it is udev-activated when a phone is plugged in |
| `libimobiledevice` (`idevice_id`) | installed |
| free disk | 33 G |
| `xtool auth status` | **Logged out** |

`sideload.sh` was run end to end on the laptop and stops cleanly at
`No iPhone visible` with the right message — no silent hang, and **no
credential prompt**, because the device check runs before the Apple ID branch.
That ordering is what makes the rehearsal safe to repeat.

## What is left, and it is only him

1. Plug the phone in with a cable, unlocked, tap Trust.
2. `cd ~/hotline && ./sideload.sh`
3. Apple ID password + 2FA — he is logged out on this laptop and the archserver
   token does not travel, by design.

No URL to fetch, no tailnet dependency, nothing to re-download. Steps 1–3 work
with the laptop entirely offline except for Apple's signing call.
