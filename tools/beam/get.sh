#!/usr/bin/env bash
# One command to fetch the kit and run the install.
#   curl -fsSL http://100.72.2.62:8790/get.sh | bash
#
# Every download resumes. Your laptop drops off the tailnet without warning,
# so this is written to be re-run as many times as it takes: it picks up where
# it stopped rather than starting the 54 MB signer again.
set -uo pipefail
BEAM=http://100.72.2.62:8790

mkdir -p ~/hotline && cd ~/hotline || exit 1

for f in HotlineCall.ipa sideload.sh xtool.AppImage SHA256SUMS; do
    printf 'fetching %s ... ' "$f"
    if curl -fL --progress-bar --retry 30 --retry-delay 3 --retry-all-errors -C - -o "$f" "$BEAM/$f"; then
        echo ok
    else
        echo
        echo "stopped on $f. Re-run this same command when you have signal;"
        echo "it resumes from here rather than starting over."
        exit 1
    fi
done

chmod +x sideload.sh xtool.AppImage

if sha256sum -c SHA256SUMS >/dev/null 2>&1; then
    echo "checksums ok"
else
    echo "CHECKSUM MISMATCH -- a file arrived corrupt. Delete ~/hotline and re-run."
    sha256sum -c SHA256SUMS
    exit 1
fi

exec ./sideload.sh
