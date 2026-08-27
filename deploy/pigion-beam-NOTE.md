# The kit is mirrored on pigion, and that is the copy that matters

archserver builds the `.ipa` and serves it on `100.72.2.62:8790` — and
archserver gets powered off. That is fine for the build, and fatal for the
install: with the box down, the one command he was given returns nothing and
the app quietly dies on his phone when the profile lapses.

So the kit is mirrored to **pigion** (`100.114.148.69`), which has been up five
weeks straight and has linger on:

    ~/hotline-beam/{HotlineCall.ipa,sideload.sh,xtool.AppImage,SHA256SUMS,README.txt,get.sh,beamd.py}
    ~/.config/systemd/user/hotline-beam.service   (enabled, tailnet address only)

`get.sh` on both hosts probes pigion first and falls back to archserver, so
either URL works, but **pigion's is the one to give him.**

## Publishing a new build

The mirror is not automatic — nothing syncs it, on purpose, because a broken
build propagating itself to the durable host is worse than a stale one.

    source /mnt/iosbuild/env62.sh
    cd app/HotlineCall && /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa
    cp xtool/HotlineCall.ipa /mnt/iosbuild/beam/
    cd /mnt/iosbuild/beam && sha256sum HotlineCall.ipa sideload.sh xtool.AppImage > SHA256SUMS
    scp HotlineCall.ipa SHA256SUMS pigion:~/hotline-beam/
    ssh pigion 'cd ~/hotline-beam && sha256sum -c SHA256SUMS'

**Refresh SHA256SUMS on both or `get.sh` will reject the download it just made.**

## Waking archserver

`ssh pigion ~/bin/wake-archserver` — a dependency-free magic packet, since
pigion is the only always-on box on the same LAN (192.168.1.8 to .139).

Verified as far as it can be without a power cycle: the NIC reports
`Wake-on: g` and `wol-enp4s0.service` re-arms it at boot, and a correctly formed
102-byte packet was confirmed *received* on archserver's udp/9 from pigion.
**What is still unproven is the BIOS half** — ErP must be disabled or the NIC
gets no standby power, and only an actual power-off proves it.
