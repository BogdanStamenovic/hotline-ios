# Getting the app onto his phone

Written from the box, 2026-08-25. Every claim about local state here was
checked by running the command, and the output is quoted.

## The short version

Three things stand between a compiled app and an icon on his home screen. I
can do the first. **The other two need him**, and no amount of routing around
changes that — they are gated on Apple's device trust and on his Apple ID, not
on any tool I am missing.

| # | Step | Who | Blocked on |
|---|------|-----|-----------|
| 1 | Compile `.ipa` | me | nothing, once the SDK is installed |
| 2 | Sign it | him + me | his Apple ID, free tier |
| 3 | Install it | him + me | phone plugged in once, "Trust" tapped |

## 1. Compile — mine

`xtool dev build --ipa` against the Darwin SDK. This is the part that has
never been done and is the current work.

## 2. Signing — needs his Apple ID

Free provisioning issues a 7-day certificate against a normal Apple ID. There
is no $99 anything here; he killed that and it is not needed for sideloading.
But signing is an Apple Developer Services login, and that means his Apple ID
and its 2FA code.

**This is his call to make, not mine and not a peer agent's.** Handing an agent
a live Apple ID session is a different question from handing it a SIP password,
because that account is also his iCloud. Options, in the order I would suggest
them:

- **He runs `xtool auth login` himself** in a terminal on the box. The token
  lands in xtool's own store; I never see the password. This is the one I would
  pick — it costs him about a minute a week.
- He gives me the credentials and I drive it. Faster to automate, and I would
  do it if he says so, but it is strictly more access than the job needs.
- An app-specific password does **not** work here — Apple Developer Services
  auth is not the same endpoint as app-specific passwords cover.

**7-day expiry is real** and SPEC §6 asks for it to be automated with a warning
before it lapses. That automation is possible for the re-sign, but it cannot be
fully unattended under option 1, because the login is his. A warning ahead of
expiry is unattended and worth having either way. Not built yet.

## 3. Installing — needs the phone physically, once

Checked on the box just now:

    $ systemctl is-active usbmuxd
    inactive
    $ ls /var/lib/lockdown/
    No such file or directory (os error 2)
    $ idevice_id -l
    ERROR: Unable to retrieve device list!
    $ lsusb | grep -i apple
    (nothing)

**The phone has never been paired with this machine.** `/var/lib/lockdown`
holding no pairing record is the direct evidence — that is where the pairing
certificate would live.

Pairing requires the phone connected **by cable** and him tapping **Trust** on
the handset with it unlocked. There is no way around this and it is not a
missing-tool problem: the trust prompt is the security boundary, and defeating
it is exactly the kind of guard rail that is out of scope here. Wireless
pairing is not supported by libimobiledevice on Linux.

The good news is it is **once**. After the pairing record exists in
`/var/lib/lockdown`, re-installs each week work over USB without re-tapping
anything, and `usbmuxd` can stay running.

### What he does, once

1. Plug the iPhone into archserver with a cable.
2. Unlock it. Tap **Trust**, enter the passcode.
3. Tell me. I run `idevice_pair pair` and confirm the record exists.

`ideviceinstaller` is **not** installed on this box, but xtool has its own
install path (`xtool install <ipa>`), so that is not a blocker.

### SideStore / AltStore — checked, does not dodge the pairing

Worth stating because it looks like an escape hatch and is not. SideStore
needs a **pairing file generated over USB from a computer** before it can
refresh over WiFi. So it has the same step 3, plus an anisette server, plus its
own Apple ID login. It buys weekly re-signing without the cable — genuinely
useful later — but it cannot remove the one-time cable step, and it is more
moving parts to get to the same first install.

Recommendation: do the plain USB path first, get the app on the phone, and
consider SideStore afterwards purely as a convenience for the weekly re-sign.

## What is NOT proven here

- **Nothing has been compiled yet.** Step 1 is a plan, not a result.
- The app has never run on a device, so nothing about its behaviour on iOS is
  verified — only that it parses, and that `Model.swift` type-checks on Linux.
- xtool's `install`/`launch` path has never been exercised from this box.
