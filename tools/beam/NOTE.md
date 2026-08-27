# What is served at http://100.72.2.62:8790/

`/mnt/iosbuild/beam` is the served directory; `hotline-beam.service`
(user unit, `deploy/hotline-beam.service`) serves it with `tools/beamd.py`.

The two text files here are the source of truth for what is served — copy them
over after editing. The three binaries in the served directory are **generated**
and deliberately not in git:

| file | where it comes from |
|---|---|
| `HotlineCall.ipa` | `xtool dev build --ipa`, then copied over |
| `xtool.AppImage` | `/mnt/iosbuild/toolchain/xtool.AppImage` |
| `SHA256SUMS` | `sha256sum HotlineCall.ipa sideload.sh xtool.AppImage` |

**Regenerate SHA256SUMS whenever you replace the .ipa**, or `get.sh` will
refuse the download it just made and tell him a file arrived corrupt.

To publish a fresh build:

    source /mnt/iosbuild/env62.sh
    cd app/HotlineCall && /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa
    cp xtool/HotlineCall.ipa /mnt/iosbuild/beam/
    cd /mnt/iosbuild/beam && sha256sum HotlineCall.ipa sideload.sh xtool.AppImage > SHA256SUMS
