# hotline-ios — architecture

Read `SPEC.md` first. This is the design that follows from it, and the reasoning
behind each choice that could reasonably have gone the other way.

## The one-line version

hotline is *one router, many transports*. This adds a transport that rings.
Nothing below the router changes.

```
  a Claude session, blocked, wanting Bogdan
                  │
                  │  hotline-call "may I spend money on a UI agency?"
                  ▼
  ┌───────────────────────────────────────────────────────────┐
  │  hotline-iosd            (archserver, Tailscale-only)      │
  │                                                            │
  │   ┌──────────────── RING TRANSPORT ─────────────────┐      │
  │   │  apns.py │ sip.py │ page.py │ loopback.py        │      │  ← swappable
  │   └───────────────────────┬─────────────────────────┘      │
  │                MediaStream │ (PCM, both directions)         │
  │   ┌───────────────────────▼─────────────────────────┐      │
  │   │  CallSession                                     │      │
  │   │    silero VAD → whisper → SessionPool.ask        │      │
  │   │              ← piper  ← speakable                │      │
  │   │    barge-in, one turn at a time, tool narration  │      │
  │   └───────────────────────┬─────────────────────────┘      │
  └───────────────────────────┼────────────────────────────────┘
                              │  reused from hotline, unmodified
                              ▼
              hotline.pool.SessionPool  →  a live Claude session
```

Two things cross a boundary and it is worth being precise about which:

- **The ring leaves the machine.** Always. Waking a sleeping iPhone traverses
  Apple's APNs, in every outcome, whoever's certificate signs the push.
- **Everything after the ring does not.** Audio, control, transcript, tool
  events, session routing: direct over Tailscale, no cloud in the path.

His instruction was "everything over Tailscale". That is achievable for
everything except the doorbell, and saying otherwise would be a lie he would
find out about the first time his phone did not ring. **APNs is the doorbell;
Tailscale is the house.**

## Why the ring transport is a plug and not an if-statement

`SPEC.md` §2 turned on a question nobody had answered: does a real CallKit ring
need a paid Apple Developer account? It does — verified twice, see `PROGRESS.md`.
But the design had to be written *before* that was known, and it still has to
survive Bogdan choosing differently from the recommendation.

So `RingTransport` (`server/src/hotline_ios/ring/base.py`) is the only place any
outcome-specific code lives:

| module | outcome | rings when closed? | whose infrastructure |
|---|---|---|---|
| ~~`apns.py`~~ | ~~A — paid ADP~~ | — | **dead, see below** |
| `sip.py` | **C** — stock SIP client | yes | Apple, via the client vendor's certificate |
| `local.py` | **B** — own app, persistent socket | *under investigation* | **none — pure Tailscale** |
| `page.py` | fallback | no | Discord/APNs, today's behaviour |
| `loopback.py` | tests and CI | n/a | none |

**Outcome A is closed.** Bogdan answered the money question on 2026-08-25:
"Just do whatever is free." The paid path is kept in this document only as the
explanation for why the free paths look the way they do. It is not an option and
should not be re-costed.

**B and C are both still open**, and he asked to be briefed on both before
choosing. Neither is built as the default yet; the server side below is what
they share, which is nearly everything.

`local.py` is the interesting one and it did not exist in the original spec. The
free tier does **not** grant Push, but it *does* grant Background modes — that
cell was verified independently as a control row, and the distinction matters. An
app holding a live audio session is not suspended, which would let it keep a
Tailscale socket open and call `reportNewIncomingCall` itself with **no push at
all** — the only shape in which "everything over Tailscale" is literally true,
doorbell included. `data-89` is stress-testing exactly this claim. It is recorded
here as a transport slot, not as a working design: battery cost, audio-session
interruption by a real phone call, and iOS reclaiming memory are all unaddressed,
and the slot stays empty until someone has run it.

`rings_when_closed` is a property on the protocol rather than a note in a
document, because it is the single fact that decides whether this project
delivered the feature, and a fact that important should be impossible to lose.

### The ring and the media are one object, deliberately

The obvious factoring is two interfaces — one that rings, one that carries
audio. It is wrong here. In every real transport the ring *establishes* the
media path: a SIP INVITE carries the SDP that describes where RTP will go, and a
VoIP push exists precisely so the app can open a WebRTC connection. Splitting
them would mean inventing a correlation id to rejoin two halves that arrived
together. So `RingTransport.ring()` returns a `MediaStream`, and returning
normally *is* the definition of answered.

## Why `CallSession` is a sibling of `VoiceCall` and not a subclass

`SPEC.md` §4 says: bridge into hotline's existing pipeline, do not fork it. Both
halves of that are honoured, but not at the same layer.

Read `hotline/src/hotline/voice.py` and roughly two thirds of `VoiceCall` is
`discord.VoiceClient` lifecycle, a `discord.AudioSource` subclass, a
`discord.sinks.Sink` subclass, and a pile of monkeypatches for six py-cord
receive bugs. None of that means anything to a transport that is not Discord,
and inheriting it would make **py-cord a hard dependency of a service whose
entire job is to work when Discord is not the answer**.

What *is* transport-independent is imported and used unmodified:

- `hotline.audio.Segmenter` — silero VAD, 0.7 s silence to end an utterance
- `hotline.audio.Transcriber` — faster-whisper `distil-large-v3`
- `hotline.audio.Speaker` — Piper
- `hotline.pool.SessionPool.ask(key, text, narrator=…, origin=…)` — the seam
- `hotline.voice.speakable` — markdown to speech
- `hotline.provenance.Origin` — how a spoken turn labels itself

`SessionPool.ask` is the whole integration. It already does routing (fresh /
attach / named agent), stand-ins for busy sessions, and narration — and it is
the exact call both `VoiceCall._handle` and hotline's iPhone Shortcut endpoint
already make. Nothing under it is reimplemented.

### Two consequences worth knowing before you touch this

1. **The iOS bridge gets its own `Transcriber` and `Speaker`.** Sharing
   hotline's would be cheaper in VRAM (~1.5 GB) but `load()`/`unload()` are not
   reference-counted, so a Discord call hanging up would unload the model out
   from under a live iOS call. Separate instances match what `bot.py` already
   does per call, and cost VRAM instead of a race.
2. **`origin` is not optional in spirit.** A spoken turn must arrive labelled as
   spoken, because a mis-transcription on a `bypassPermissions` session has no
   undo, and the session cannot exercise judgement about that if it cannot tell
   speech from typing.

## Why the format conversion is not hotline's

`hotline.audio` has `stereo48_to_mono16` and `mono_to_stereo48`. The rate and
channel count are in the function names, which is correct when Discord is the
only caller and wrong the moment anything else is. SIP is 8 kHz mono G.711;
WebRTC is 48 kHz. `media/pcm.py` is the same arithmetic with the constants
passed in.

G.711 is implemented there rather than depended on. That is the reason the SIP
transport has **no third-party dependency at all**: µ-law is the one codec every
SIP client on earth is required to support, and it is a 256-entry lookup table.
The encode table is built by inverting the decode table by nearest neighbour
rather than by reimplementing the segment arithmetic, so the two directions
cannot drift apart — a round trip is exact by construction, which is what the
test checks.

## Barge-in is why outbound audio is a queue

You cannot un-send a write. Interrupting Claude mid-sentence means discarding
audio that has been synthesised but not yet played, so outbound frames sit in a
`deque` the transport drains at the frame clock, and interrupting is
`clear()`. hotline reached the same design for the same reason in
`StreamSource`; this is not a coincidence, it is the constraint.

A `deque` rather than an `asyncio.Queue` specifically, because `asyncio.Queue`
has no supported way to drop its contents — reaching into `_queue` breaks its
unfinished-task accounting.

## `hotline-call` degrades to `hotline-page`, always

The replacement for a thing that currently works must never be worse than the
thing it replaces. If the daemon is down, no transport is registered, or the
call rings out, `hotline-call` shells out to `hotline-page` with the same
arguments and inherits its stdout, so `$(hotline-call …)` still yields his
answer. Exit codes 0/1/2/3 are `hotline-page`'s exactly.

The one addition is **exit 4, declined** — which a mention could not express.
A decline is a real answer, and it is the one case that is deliberately *not*
escalated to a Discord page: he saw it and said not now, and ringing him again
through another channel one second later is precisely what he was declining.

## Security

Inherited from hotline, not reinvented, because the threat is identical: a call
is root-equivalent. `bypassPermissions`, `%wheel NOPASSWD: ALL`, and speech
recognition in the path with no confirmation step.

- **Bind and gate on Tailscale.** Same source-IP allowlist as `hotlined`
  (`HOTLINE_ALLOW_IPS`), plus the optional `X-Hotline-Key` second factor.
- **The `PreToolUse` denylist already exists** and covers the catastrophic,
  undoable commands. It is machine-wide, so it covers this transport for free.
- **A call must identify itself as spoken** (see `Origin`, above).

## Open questions, tracked honestly

- **Outcome C's load-bearing unknown:** a self-hosted, Tailscale-only SIP
  backend actually causing the stock Linphone app to ring when closed. The push
  goes through the vendor's gateway with the vendor's Apple certificate; whether
  that gateway will do it for a private backend, for free, is being verified.
  **If it will not, outcome C collapses** and Bogdan must know before he chooses.
- **Outcome B's load-bearing unknown:** whether a persistent audio session can
  keep a sideloaded app alive reliably enough to be a doorbell (`local.py`,
  above). The usual objection — Apple rejects apps that do this — does not apply
  to something sideloaded onto one's own phone, which is why it is worth
  testing rather than dismissing. `data-89` has it.
- Both unknowns are *empirical*, and neither is settled by reading. Whichever
  survives being run is the one to build.
