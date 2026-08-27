#!/usr/bin/env bash
# One command to fetch the kit and run the install.
#   curl -fsSL http://100.114.148.69:8790/get.sh | bash
#
# Served from pigion, which stays up. archserver also serves this on
# 100.72.2.62:8790 but gets powered off, so pigion is the durable copy and
# archserver is the fallback rather than the other way round.
#
# Every download resumes. Re-run it as many times as it takes.
set -uo pipefail
HOSTS="100.114.148.69 100.72.2.62"

mkdir -p ~/hotline && cd ~/hotline || exit 1

beam=""
for h in $HOSTS; do
    if curl -fsS --max-time 8 -o /dev/null "http://$h:8790/SHA256SUMS" 2>/dev/null; then
        beam="http://$h:8790"; echo "using $beam"; break
    fi
done
if [ -z "$beam" ]; then
    echo "Neither box is reachable. Check tailscale is up on this laptop:  tailscale status"
    echo "If archserver is powered off that is fine -- pigion should still answer."
    exit 1
fi

for f in HotlineCall.ipa sideload.sh xtool.AppImage SHA256SUMS; do
    printf "fetching %s ... " "$f"
    if curl -fL --progress-bar --retry 30 --retry-delay 3 --retry-all-errors -C - -o "$f" "$beam/$f"; then
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
