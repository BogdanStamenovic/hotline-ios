# hotline-ios

The hotline iPhone app and the server it talks to, `hotline-iosd`: the roster
of Claude Code agents on `archserver`, their channels and history, the controls
(stop, retask, compact, resume, new), delegation (typing an instruction to an
agent from the phone), and the conversations a ring opens.

**Phone calls are not here any more.** On 2026-10-31 Bogdan moved call
semantics out (Discord 1566035363657420962): the SIP ring, inbound calls, the
media stack, the voices that talk on a call and the `hotline-call` CLI are
[`hotline-call`](https://github.com/BogdanStamenovic/hotline-call), with their
history. This repository is the iOS backbone.

## How it meets hotline-call

```
agent ── hotline-call ──▶ hotline-calld :8792 ── rings ──▶ his iPhone
                              │   ▲
   /api/v1/conversations/*    │   │  /api/v1/call/reply, /api/v1/call/hangup
   (each call, best effort)   ▼   │  (his typed answer, his dismissal)
                          hotline-iosd :8789 ◀──── the iPhone app
                          /api/v1/call is forwarded to :8792 for old callers
```

| what | where it lives | why |
|---|---|---|
| the conversation a ring opens, its feed, his typed reply | here, in the store | the app lists the question before the phone rings and he answers it by typing |
| the ring, the voice, Whisper, PersonaPlex, inbound | hotline-calld | a phone call is one question with its own failure modes (GPU handoff, SIP registrar) |
| `/api/v1/call` on 8789 | forwarded unchanged to hotline-calld | agents and scripts that post here keep working during the transition |
| `/health` `ok`, `fake`, `ring_ready`, `transport` | copied from hotline-calld's `/health`, asked each time | the app's `Health` decoder and the call-bogdan skill read them here |

New endpoints for hotline-calld (same allowlist and key as everything else):

| route | body | |
|---|---|---|
| `POST /api/v1/conversations/open` | `{conversation, agent, kind}` | `kind` is `ring` (an agent blocked on him) or `say`; idempotent |
| `POST /api/v1/conversations/append` | `{conversation, kind, text}` | `kind` in claude, summary, you, state, error |
| `POST /api/v1/conversations/close` | `{conversation}` | |

`/api/v1/reply` and `/api/v1/hangup` behave as before and are also forwarded to
hotline-calld in the background, so a `hotline-call` blocked on him returns.

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
  daemon.py     hotline-iosd: roster, channels, control, delegation, conversations
  calld.py      the way to hotline-calld: the forward, the health, the reply hand-off
  store.py      SQLite: agents, conversations, events, phases
  events.py     the in-memory feed with a cursor and a long-poll wait
  ingest.py     reading Claude Code transcripts into the map
  hooks.py      hotline-ios-hooks: the map hook and statusline wrapper
  endpoint.py   where the daemon listens, and where local tooling reaches it
  vitals.py     output rate, tools per minute
app/HotlineCall/    the iOS app
ci/                 the simulator and UI-test harness
deploy/, tools/     the live unit, the .ipa beam, profile watch
docs/               architecture, server plan, design
```

## Install

```bash
ownbox install hotline-ios --yes
```

`./ownbox.sh setup` builds `server/.venv` with uv (Python 3.12, `-e
server[hotline,dev]`), writes `.env` from `.env.example` if there is none,
renders `systemd/hotline-ios.service.in` into the user unit and starts it, and
offers to register the map hook (skipped without a terminal, because it edits
the settings every session on the box uses). A hand-written
`~/.config/systemd/user/hotline-ios.service` -- archserver has one -- is left
alone and reported. `update` rebuilds the venv and restarts a unit it owns; the
store migrates itself on open. `remove` takes the unit away and asks before
deleting the store.

Calls need hotline-call installed and running: `ownbox install hotline-call`.

## Running the tests

One venv, no GPU, no models; hotline's *source* on the path, not its
dependencies.

```bash
cd server
PYTHONPATH=/home/bodas/data/hotline/src:src .venv/bin/python -m pytest -q tests
```

152 passed in 1.3 s on archserver (2026-10-31).

## Limitations

- **Calls depend on a second daemon.** With hotline-calld down, `/health` says
  `ok: false`, `/api/v1/call` is a 503 (which `hotline-call` turns into a
  `hotline-page` fallback), and the rest of the app works.
- **A typed answer reaches a waiting call only if the forward lands.** The
  answer is stored here regardless; a failed forward is counted on `/health`
  under `calld.forward_failures` and is not retried.
- **A call opened while this daemon was down never appears in the app.**
  hotline-calld's mirror is best effort and does not replay.
- **The `/api/v1/call` forward is transitional.** Removing it, once nothing
  posts to 8789 for calls, is a separate change.
- **`hotline-ios-hooks` cannot be re-run safely on a box where it is already
  installed:** a second run rewrites the statusline wrapper without the command
  it wrapped. `ownbox.sh` therefore never re-runs it.

