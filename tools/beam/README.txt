hotline-ios — sideload kit
==========================

Served from the Arch box at http://100.72.2.62:8790/

ONE COMMAND, on the laptop, with the phone plugged in and unlocked:

    curl -fsSL http://100.72.2.62:8790/get.sh | bash

That fetches everything, checks it arrived intact, and runs the install.
**Every download resumes.** If your link drops, run the same command again --
it picks up where it stopped instead of restarting the 54 MB signer.

It will ask for your Apple ID the first time (password typed, plus a 2FA code).
That login has to happen on the laptop: the token on the Arch box is a
credential and does not travel.

Files, if you would rather do it by hand:

    HotlineCall.ipa    9.9 MB, unsigned, arm64, iOS 18+
    sideload.sh        signs it with your Apple ID and installs it
    xtool.AppImage     the signer/installer (Linux)
    SHA256SUMS         checksums for the three above

Timing — this is the part that matters
--------------------------------------

The provisioning profile expires **1 September 22:53**, and you are back on the
**9th**. So the app WILL stop launching for that gap unless you run the command
above before the 1st. Re-running it renews for another 7 days; it is the same
command every time.

You will NOT hit the "maximum number of registered devices" error that stopped
the first attempt. Your phone is already registered and enabled under your team
(checked against Apple on 27 Aug), so there is no new device to register.

What this build is
------------------

Built on the Arch box 27 Aug 10:22 from `main`. It includes the conversation
screen redesign that has never been on your phone -- the sparkline and the
per-row duration bars are gone from the transcript, the PHASE/OUTCOME labels
moved above the sentence instead of sitting in a left-hand column, and the
state line took the orange instead of a decorative rule. The build on your
phone now is from 26 Aug 04:16 and has none of that.

The three header chips (ROUTE-N / RETIRE / DELETE HISTORY) are still there
rather than collapsed into one pill, because you asked for somewhere to retire
and delete. Say if you want them moved into the control sheet.

What this build talks to
------------------------

The daemon on 100.72.2.62:8789, which is running and current. The phone must be
on the tailnet. Nothing else needs starting.

What to actually check, in order
--------------------------------

From docs/APP-PLAN.md 13. "It launched" is not the bar.

 1. Hold it up. Does the density and the type read right on a real screen?
    (If the wordmark is NOT Geist, the font failed to register -- say so, it
    is a one-line fix.)
 2. Leave it open ten minutes without touching it. The list must change on
    its own.
 3. Drag from the left edge to halfway and back without letting go. Does it
    track 1:1? Fling it back and immediately tap the row again -- does it
    retarget without jumping?
 4. Open a channel and say nothing. Messages must arrive.
    Back out, open a different agent. The thread must be that agent's,
    immediately.
    Send "yes" twice. Both must survive.
    Kill the app, reopen a channel. History must be on screen before a
    spinner would have appeared.
 5. Open a dead agent. Every readout zero, every mark still.
    Open a busy one, watch the context bar for a minute. It must move, and
    only when a real sample lands.
 6. Compact a real session and watch the context bar fall.
 7. Block an agent from the CLI while watching the list. The climb must
    visibly overtake the parting rows.
 8. Scrub the full session in the map. The timeline must follow without
    oscillating.
 9. The slam card's 320 ms held beat -- does it hold long enough to read?
10. Purge a scratch agent. The phone's copy must go and stay gone.

Known, and not a fault in this build
------------------------------------

Swipe a row open, swipe it closed, then tap any row -- that first tap is eaten
and you need a second. Standard iOS: the tap that dismisses a swiped row does
not also navigate. Tell me if it annoys you on the actual phone and I will
change it.
