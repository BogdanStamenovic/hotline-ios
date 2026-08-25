
## 2026-08-25, 22:53 — it installed, and the reason is in the timestamps

He re-ran it and it went through. An unexplained success is fragile, so I went
looking for the mechanism rather than taking the win.

    devices:      25RYBYG6YU  "Bogdan"  iPhone 15 Pro  ENABLED
                  udid 00008130-001669590ABA001C   added 22:53
    identifiers:  XTL-3GAQP72Y5Z.dev.stamenovic.hotlinecall
    profile:      ACTIVE, created 22:53, EXPIRES 01/09/2026 22:53
    certificate:  Apple Development: Bogdan Stamenović, expires 2027

**The Spotify identifier is gone.** At 22:45 `ds identifiers list` returned
`com.spotify.client.3GAQP72Y5Z` and nothing else; at 22:55 it returns only the
hotline one. His old free-provisioning artifacts were aging out during exactly
the window the install started working, and App IDs and device registrations
carry the same 7-day timer.

So the sequence was: a stale registration hit its expiry somewhere around
22:50, a slot opened, and the next attempt took it. **Apple's own answer —
"simply wait" — was correct; the wait just happened to be ten minutes rather
than seven days because something was already at the end of its timer.**

The devices list was never broken either. It was empty because there genuinely
was nothing visible to list, and it is populated now.

### Where I was wrong

The facts I gave him held up — 3 devices, 7-day expiry, no removal route for a
free account, all first-party. What I got wrong was the conclusion drawn from
them: I presented a second Apple ID as the thing that would unblock tonight and
treated waiting as useless. Waiting was the answer, and I had the mechanism in
front of me that explained why a slot could free at any moment.

### And a bug of mine, caught before he hit it

The daemon was bound to `127.0.0.1`. I passed that when restarting it during the
loopback fix and never put it back. **His phone cannot reach loopback**, and I
had already told him to type `100.72.2.62` into the app — it would have hung on
a timeout that looks exactly like archserver being down, which is the failure
mode `Server.swift` was written to avoid.

Rebound to the Tailscale address and checked both halves of SPEC section 4:

    LISTEN 100.72.2.62:8789          reachable over the tailnet
    192.168.1.9:8789                 not bound -- nothing on the LAN

Phone is on the tailnet and answers at 86 ms via DERP.

**Still unproven: the app has never been opened.** Installed is not running.
