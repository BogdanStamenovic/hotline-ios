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

---

# He ran it — 27 Aug 16:24

Reported over the phone channel (no receipt, so evidence not proof) and then
**corroborated on a machine he would have had to touch himself**: the laptop's
`xtool auth status` flipped from `Logged out` to

    Logged in.  bogdan.stamenovic@gmail.com  team 3GAQP72Y5Z
    Token expiry: 27/08/2027, 4:23 PM

That token can only exist if a human typed his Apple ID password and a 2FA code
on that laptop, eight minutes after the push landed. Apple agrees — a new
profile exists:

    created    27/08/2026, 4:24 PM
    expires    03/09/2026, 4:24 PM
    device     00008130-001669590ABA001C   (his iPhone 15 Pro)

## The deadline moved and got cheaper

**2 September 04:16 is dead. The real date is 3 September 16:24.** The seven
days run from *install*, which is exactly why the handoff says to ask the
authority instead of deriving it — and it is why the answer changed the moment
he installed.

He is still away until 9 September, so the app still dies mid-trip. But the
re-sign is no longer a download-and-log-in job:

    cd ~/hotline && ./sideload.sh        # phone on the cable, unlocked

No fetch, no tailnet, and **no 2FA** — the laptop's token is good until
August 2027. Roughly a minute, offline apart from Apple's signing call.

## The reminder no longer dies with this box

`hotline-profile-watch.timer` queries Apple live, so it tracks 3 September on
its own with no edit. Its real weakness was never the date: **it runs here, and
here gets powered off.**

Closed from pigion, which has been up 39 days. `wake-archserver-for-profile
.timer` there fires `~/bin/wake-archserver` at 09:40 on 30, 31 Aug and 1, 2,
3 Sept — five explicit dates, so it expires by itself and leaves no cruft.
archserver's watcher is `Persistent=true`, so a late wake still gets the missed
check; the packet only has to land some time that day. Exercised for real, not
just enabled: `sent 102-byte magic packet ... 192.168.1.255:9`.

**This is best-effort, and the reason is unchanged from the last handoff: the
BIOS half of WoL is still unproven.** ErP has never been tested through a real
power-off. Do not read this as "the reminder is guaranteed" — read it as the
reminder now has a path that does not require archserver to already be on.

Undo, if he wants it gone:

    ssh pigion 'systemctl --user disable --now wake-archserver-for-profile.timer &&
                rm ~/.config/systemd/user/wake-archserver-for-profile.*'

---

# New build pushed to the laptop — 27 Aug 16:50

`HotlineCall.ipa` sha256 `1f85707b…c86379`, carrying the three fixes he
reported from the phone (prose truncation, the unclosable map, the transcript
rebuilding every row). Landed and checksum-verified in all three places:
`/mnt/iosbuild/beam` here, `~/hotline-beam` on pigion, and **`~/hotline` on the
laptop** — the last one matters most, because he is not reliably on the tailnet
and that is the whole reason the kit is pushed rather than pulled.

The truncation half is server-side and is **already live**; `hotline-ios` was
restarted at 16:49 and real `claude` events are landing from ingest, one of them
2811 characters with its paragraph breaks intact. He does not need to reinstall
for that.

## The previous build is kept beside it

`HotlineCall-prev.ipa`, sha256 `26669c8c…c88ab` — byte for byte what he
installed at 16:24. **Deliberately absent from `SHA256SUMS`**, because `get.sh`
runs `sha256sum -c` over that file and only ever downloads the three it names;
listing a fourth would make every fetch fail on a file it never asked for.

Rollback is local and needs no network:

    cd ~/hotline && cp HotlineCall-prev.ipa HotlineCall.ipa && ./sideload.sh

This exists because **nobody has ever run this app.** It compiles here in
seconds and the wire tests execute real app code on Linux, but no view has been
rendered outside a macOS simulator, and he is about to depend on it for two
weeks. A build that cannot be undone from a train is not one worth pushing.

## Re-signing now costs him nothing extra

`xtool auth status` on the laptop: logged in, token good to **27/08/2027**. So
installing this build — or rolling back — costs no Apple ID password and no 2FA
round. Any note saying otherwise predates his 16:23 login.
