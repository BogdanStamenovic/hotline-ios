# hotline-ios

A real ringing call from a Claude Code session on `archserver` to Bogdan's
iPhone. Full-screen native call UI, a ringtone, answer or decline, and a live
transcript of what Claude is doing while you talk to it.

It replaces the escalating Discord `@mention` that stands in for a call today.
He calls that a fake call and he is right: it is a push notification, it does
not ring, and it does not present as a call.

This is the client and the transport. The server side — session routing, VAD,
Whisper, Piper, tool-call narration — is [`hotline`](../hotline), and this
reuses it rather than rebuilding it.

## What works today

- **The call pipeline, end to end, in tests.** Audio in, segmented, transcribed,
  routed into a live Claude session, answered, spoken back, with barge-in and
  tool-call narration. 64 tests, ~3 seconds.
- **`hotline-call`** — the replacement for `hotline-page`. Same arguments, same
  exit codes, and it falls back to `hotline-page` when a call cannot be
  delivered, so adopting it is never worse than staying put.
- **`hotline-iosd`** — the service that places calls, gated on Tailscale, with a
  live event feed the phone reads.
- **The SIP probe** — a running instrument that answers one question about
  outcome C by capturing what a SIP client actually puts on the wire.
- **The iOS app source** — CallKit, live transcript, tool display.
- **A Swift toolchain that runs on this Arch box**, with an iOS project
  scaffolded and building up to the SDK step.

## What does not exist yet

- **No ring transport is chosen, so nothing rings yet.** Two free options are
  live and neither has been proven on his actual phone. The transports are
  swappable modules precisely because this was not settled when the code was
  written.
- **The app has never been built into an `.ipa`**, because that needs Apple's
  Darwin SDK. See below.
- **The app has never run on a phone.** Nothing in it is device-tested.
- **No audio has crossed a real network.** The RTP layer is tested against
  itself over real sockets, not against a handset.
- **The 7-day re-sign story is documented, not automated.**

## The two free ways to make it ring

The paid Apple Developer Program ($99/yr) is **closed** — he chose free. It is
mentioned only because it explains the shape of what follows.

**Neither option can put the doorbell on Tailscale unconditionally**, and that
is worth saying plainly since "everything over Tailscale" was the ask. Audio,
control, transcripts and session routing are all direct over the tailnet with no
cloud in the path. The ring is the part that may have to leave it.

### B — his own app

The app holds a socket open to `archserver` and calls
`CXProvider.reportNewIncomingCall` itself. **No push, no APNs, nothing leaves
the tailnet** — the only shape in which the ask is literally true.

CallKit needs no entitlement, which is why this is possible on a free Apple ID.
Push does, and free provisioning does not grant it, verified against Apple's own
capabilities table.

The catch is that **a push wakes a dead process and a socket cannot.** After a
reboot, a force-quit, a certificate expiry, or an audio session interrupted by
an ordinary incoming phone call, nothing rings — silently. It also needs
sideloading, and re-signing every 7 days, and iOS allows only one VPN profile,
so SideStore's loopback VPN and Tailscale collide.

### C — the stock Linphone app

Linphone registers to a SIP server on `archserver` and Belledonne's push relay
rings it. **Works with the app closed and the phone locked.** No Apple account,
no sideloading, no re-signing.

The mechanism is the designed one, not a trick: RFC 8599 has a client hand its
push token to its SIP server precisely so that server can trigger the push.
Belledonne's own server code shows the endpoint takes ordinary account auth and
does no ownership check.

The catch is that the ringing app has someone else's name on it, and their relay
is in the doorbell path.

**The chosen composition is not to choose.** `RingChain` runs them in order and
falls through: his app if its socket is alive, Linphone if not, the Discord
mention if neither, the siren last. `ConfirmedRing` makes that meaningful by
requiring each transport to *prove* the phone rang — otherwise a chain does not
degrade, it just stops at the first transport that fails silently.

## Building an iOS app on Linux

There is no macOS and no Xcode here, and it turns out that is **an account
problem rather than a machine problem.**

Working on this box today, verified by running it:

| | |
|---|---|
| Swift 6.3.3 | compiles and runs |
| xtool 1.17.0 | runs, scaffolds an iOS SwiftUI project |
| `xtool dev build` | reaches SwiftPM planning |
| The Darwin iOS SDK | **the only missing piece** |

`xtool sdk install` accepts only `Xcode.xip` or `Xcode.app`, and Apple gates that
download behind an authenticated browser login. The way around it is a GitHub
Actions macOS runner, which already has Xcode installed — so the SDK can be
built there and copied back, and the 13 GB download never happens.

Two Arch-vs-Ubuntu ABI gaps had to be solved and both were solved **without
installing anything system-wide**: ncurses by symlinking the wide build, libxml2
and ICU by extracting the real `.so` files from Ubuntu's own `.deb`s, since both
are major soname bumps where a symlink would crash later rather than fail now.
Everything lives in a private tree that one `rm` undoes.

## Layout

```
server/src/hotline_ios/
  ring/base.py      the seam every outcome plugs into
  ring/watch.py     require a transport to prove the phone rang
  ring/chain.py     fall through from one way of reaching him to the next
  ring/loopback.py  no phone at all; what the tests run against
  media/rtp.py      RTP + G.711 + a jitter buffer sized for the real path
  media/pcm.py      format conversion, and G.711 as a lookup table
  call.py           one call, independent of how it rang
  daemon.py         hotline-iosd
  call_cli.py       hotline-call
  sipprobe.py       the instrument that settles outcome C
app/HotlineCall/    the iOS app
docs/               architecture, and the five-minute SIP experiment
```

## Running the tests

One venv, no GPU, no models. The delegation path never touches Whisper or
Piper, so this needs only hotline's *source* on the path, not its dependencies.

```bash
cd server
PYTHONPATH=/home/bodas/data/hotline/src:src .venv/bin/python -m pytest -q tests
```
