# hotline-ios — architecture

Read `SPEC.md` first. This is the design that follows from it, and the reasoning
behind each choice that could reasonably have gone the other way.

## The one-line version

**Telegram rings. His app is the interface. Nothing carries voice.**

That separation is Bogdan's, made on 2026-08-25, and it is the whole
architecture. Everything proposed to him before it assumed the thing that
*rings* is the thing you *talk through* — and paying for that assumption is
what made every earlier option fragile.

```
  a Claude session, blocked, wanting Bogdan
                  │
                  │  hotline-call "may I spend money on a UI agency?"
                  ▼
  ┌───────────────────────────────────────────────────────────┐
  │  hotline-iosd            (archserver, Tailscale-only)      │
  │                                                            │
  │   1. write the question into a conversation  ─────────┐    │
  │   2. ring him                                          │    │
  │      ┌──────── RingChain, in order ──────────┐         │    │
  │      │  telegram.py │ sip.py │ page (Discord) │         │    │
  │      └──────────────┬────────────────────────┘         │    │
  │            each wrapped in ConfirmedRing               │    │
  │                     │                                   │    │
  │   3. wait for him to type an answer  ◄─────────────────┘    │
  └─────────────────────┼───────────────────────────────────────┘
                        │ he opens the app
                        ▼
        ┌───────────────────────────────┐
        │  HotlineCall.app  (sideloaded) │
        │   pick an agent │ see who's live│
        │   type          │ live transcript│
        │                 │ what tool it's │
        │                 │ running now    │
        └───────────────┬───────────────┘
                        │ POST /api/v1/say, over Tailscale
                        ▼
             hotline.pool.SessionPool.ask  →  a live Claude session
```

Two things cross a boundary, and only one of them has to:

- **The ring leaves the tailnet.** Always, under every option, at every price.
  Waking a locked iPhone means somebody's push infrastructure — Apple's,
  Belledonne's, or Telegram's. Paying Apple $99 would only have changed whose.
- **Everything else does not.** The app, the transcript, tool events, session
  routing, the instructions he types: direct over Tailscale, no cloud.

**APNs is the doorbell; Tailscale is the house.** That sentence was written when
the doorbell was expected to be Apple's, and it survived three changes of
doorbell unchanged, which is a reasonable sign it was the right shape.

## Why the doorbell is a plug and not an if-statement

This was designed before anyone knew what would ring, deliberately. It then went
through **four** answers in one day: a paid Apple account, his own app over a
tailnet socket, a stock SIP client, and finally Telegram — plus a late "actually,
both". `RingTransport` absorbed every one of them **without a rewrite above it**,
and "we will do both" turned out to be a configuration rather than a fork.

A ring transport now has exactly one job:

```python
async def ring(self, target: CallTarget, *, timeout: float = 45.0) -> None:
    """Ring, or raise. Returning means it rang."""
```

It used to also return a `MediaStream`. That existed only while the ringer was
assumed to be the talker; when he split them, the audio came out of the
interface entirely. The code shed it before this document did.

| transport | rings a closed app? | whose infrastructure | state |
|---|---|---|---|
| `telegram.py` | **yes** | Telegram's | built, **never run against his phone** |
| `sip.py` (Linphone) | **yes** | Belledonne's | probe running, awaiting his handset |
| `page` (Discord mention) | no — it is a notification | Discord's | already works today |
| `loopback.py` | n/a | none | what the tests run against |

`rings_when_closed` is on the protocol rather than in a document, because it is
the single fact that decides whether a transport delivers the feature, and a
fact that important should be impossible to lose.

## A ring is not delivered because we asked for it

`ConfirmedRing` is the piece that survived every change of design, and the only
one that got *more* important each time.

Every doorbell fails silently, in its own way. Telegram can refuse on a privacy
setting. Belledonne can tighten an endpoint or drop a free tier. A sideloaded
app's certificate expires after seven days. **In none of those does anything
raise** — the call simply never arrives, the agent that placed it waits, and
Bogdan is never told.

That is worse than the Discord mention it replaced, because he will have learned
to trust it.

So a transport must produce positive evidence, and silence is converted into
`CallUnreachable`, which `RingChain` turns into the next transport and
`hotline-call` turns into a Discord page. **It fails closed**: a transport with
no confirmation channel is reported unreachable rather than trusted, because "I
could not tell" has to mean no.

`RingChain` is only meaningful because of this. A fall-through chain over
transports that cannot report success does not degrade — it stops at the first
one that fails quietly.

### One correction, kept visible

An earlier version justified this with an Apple Developer Forums thread in which
an engineer supposedly said a packet tunnel provider is suspended on lock,
"100%, no". **Nobody could verify that quote** — the page serves a JavaScript
shell with none of the quoted terms, and the forums API 404s. It reached this
design through three agents, gaining confidence at every hop and verified at
none. I was the hop that wrote it into the source.

Then someone measured his actual phone: **20/20 `tailscale ping` answered while
locked and idle, 0% loss, present in 14/14 peer-map samples.** The strong claim
was simply wrong.

What stands is checkable and sufficient: a Tailscale contributor on
`tailscale/tailscale#17575` describing a **5-10 s** wait while iOS starts the
VPN from an on-demand rule, and a measured path that is DERP-relayed at
92-623 ms and never once direct.

**The mechanism did not change**, which is exactly why the bad citation was
dangerous rather than merely wrong: it made a sound design look like it depended
on a lie.

## `hotline-call` keeps `hotline-page`'s contract

There is already a `call-bogdan` skill and an unknown number of agent prompts
doing `answer=$(hotline-page "...")`. Exit codes 0/1/2/3 mean exactly what they
meant. Only one is added — **4, declined** — which a mention could not express.

The subtlety the change of doorbell created: **the thing that rings and the
thing he answers in are now different programs.** So the daemon writes the
question into a conversation *before* ringing, rings, and then waits for him to
type. A blocked agent still gets his words on stdout and never learns that two
programs were involved. Ring-and-exit would have quietly broken every caller.

Three consequences worth stating:

- **The question is in the app before the phone rings.** Whether he opens it
  during the ring or an hour later, it is there. He never answers to silence.
- **A ring-out leaves the conversation open.** He may well answer five minutes
  later, and closing it would throw away the reply he is about to give.
- **A decline does not fall through.** He saw it and said not now; ringing him
  by another route a second later is precisely what he was declining. This is
  the difference between escalating and harassing.

## The app is a client, not a phone

Native Swift, sideloaded, re-signed weekly — a cost he accepted explicitly and
unprompted. It has **no CallKit, no PushKit, no audio, and no keepalive**,
because it does not have to ring. That deletes every one of the failure modes
that made outcome B fragile: force-quit, reboot, certificate expiry, and an
audio session killed by an ordinary incoming phone call.

Two decisions in it worth knowing:

- **Long-poll with a cursor, not a socket.** The phone moves between wifi and
  cellular and every long-lived connection dies at the handover. A streaming
  transport does not remove reconnect logic, it adds it, and then needs replay
  on top so the gap loses nothing. Once you have built that cursor, the socket
  carries almost nothing the cursor could not. When the server reports a gap the
  transcript says so *in itself* — a hole nobody is told about looks exactly
  like nothing happening.
- **Every tool event reaches the screen.** hotline throttles narration because
  speech is serial and would talk over the answer. A screen has neither
  constraint. That is the whole reason the server emits tool events to both.

## What is reused rather than rebuilt

`SPEC.md` §4 says do not fork hotline's pipeline, and nothing here does. The
integration is one call:

```python
SessionPool.ask(key, text, narrator=…, origin=…)
```

which already handles routing (fresh / attach / named agent), stand-ins for busy
sessions, and progressive tool events. `pool.bind` targets a named agent;
`Registry` says who is alive. The daemon adds a `narrator` that also pushes each
event to the phone — a pure consumer-side addition, no core changes.

Since the voice route is gone, **the daemon no longer imports Whisper, Piper or
soxr at all.** It needs hotline's source on the path, not its wheels.

A turn from the app is labelled `kind="phone"`, deliberately not `"voice"`:
there is no speech recognition in this path any more, and claiming a
mis-hearing risk that does not exist would make the label useless where it does.

## Security

Inherited from hotline, not reinvented, because the threat is identical: a
delegated instruction runs with `bypassPermissions` on a box with
`%wheel NOPASSWD: ALL`. **Treat it as root-equivalent.**

- Bind and gate on Tailscale — the same source-IP allowlist as `hotlined`, plus
  the optional `X-Hotline-Key`. Loopback is always allowed, because a blocked
  agent runs on this box and must not be locked out by its own allowlist.
- The `PreToolUse` denylist already exists and is machine-wide, so it covers
  this transport for free.

## What is not proven

Nothing here has run against his phone. Specifically:

- **The Telegram ring has never fired.** It needs an `api_id`, an `api_hash`, a
  second account with its own phone number, and his handset.
- **The SIP probe has never seen a real client.** It answers its own tests over
  a real socket; no Linphone has registered to it.
- **The app has never been built into an `.ipa`**, and has never run on a
  device.
