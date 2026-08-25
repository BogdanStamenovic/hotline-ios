#!/usr/bin/env bash
# Sideload HotlineCall onto the iPhone, from the Arch laptop.
#
# Everything here runs on YOUR machine against YOUR Apple ID. Nothing is sent
# anywhere except to Apple (to sign) and to the phone on the cable.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IPA="$HERE/HotlineCall.ipa"
APPIMAGE="$HERE/xtool.AppImage"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
warn() { printf '\033[33m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$IPA" ]      || die "HotlineCall.ipa is not next to this script."
[ -f "$APPIMAGE" ] || die "xtool.AppImage is not next to this script."
chmod +x "$APPIMAGE"

# --- xtool, with a fallback for a laptop without FUSE -------------------
XTOOL="$APPIMAGE"
if ! "$APPIMAGE" --version >/dev/null 2>&1; then
    warn "The AppImage will not run directly (usually a missing FUSE). Extracting instead."
    ( cd "$HERE" && "$APPIMAGE" --appimage-extract >/dev/null ) \
        || die "Could not extract the AppImage either. Send me the error."
    XTOOL="$HERE/squashfs-root/AppRun"
fi
say "xtool: $("$XTOOL" --version)"

# --- the phone ----------------------------------------------------------
if ! command -v usbmuxd >/dev/null 2>&1; then
    warn "usbmuxd is not installed. On Arch:  sudo pacman -S usbmuxd libimobiledevice"
    warn "Install it, plug the phone in, and re-run this script."
    exit 1
fi
# Hard requirement, not a nicety. Tested on archserver: `xtool install` with
# no device attached prints NOTHING and blocks indefinitely -- no error, no
# timeout. Checking with idevice_id first is what turns that silent hang into
# the message below.
if ! command -v idevice_id >/dev/null 2>&1; then
    warn "libimobiledevice is not installed. On Arch:  sudo pacman -S libimobiledevice"
    warn "Needed to detect the phone. Without it xtool hangs silently instead of"
    warn "telling you the phone is not there."
    exit 1
fi

say "Looking for the phone..."
if ! idevice_id -l 2>/dev/null | grep -q .; then
    cat <<'EOF'
No iPhone visible. Check, in this order:
  1. It is plugged in with a CABLE (not just charging on a dock).
  2. It is UNLOCKED.
  3. You tapped "Trust This Computer" and entered the passcode.
     If you never saw that prompt, unplug and replug while unlocked.
  4. usbmuxd is running:  systemctl start usbmuxd
EOF
    exit 1
fi
say "Phone found: $(idevice_id -l | head -1)"

# --- Apple ID -----------------------------------------------------------
# Signing needs a login on THIS machine. The token on archserver does not
# travel; it is a credential and it stays where it was made.
if ! "$XTOOL" auth status 2>/dev/null | grep -qi "logged in"; then
    say "Not logged in on this laptop. Logging in now."
    echo "Your Apple ID, its password (typed, not shown), and a 2FA code."
    "$XTOOL" auth login --mode password || die "Login failed."
fi
"$XTOOL" auth status | sed 's/^/  /'

# --- sign and install ---------------------------------------------------
# xtool dev build does NOT sign; xtool install does, because a free
# provisioning profile is bound to the device's UDID and cannot be made
# without the device present. That is why this step needs the cable.
say "Signing and installing..."
echo "(If this sits silent for more than a couple of minutes, the phone has"
echo " dropped off. Ctrl-C, replug, re-run.)"
if "$XTOOL" install "$IPA"; then
    say "Installed."
    cat <<'EOF'
On the phone, first launch only:
  Settings > General > VPN & Device Management > your Apple ID > Trust

Then open Hotline and give it archserver's address:  100.72.2.62
(port 8789 is assumed)

The free certificate lasts 7 DAYS. Re-run this script to renew it.
EOF
else
    die "Install failed. Send me everything above this line."
fi
