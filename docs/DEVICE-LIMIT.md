# Why the install failed: Apple's free-tier device limit

`xtool install` got all the way to `[Provisioning] 0%` and then:

    403 FORBIDDEN_ERROR
    "Your development team has reached the maximum number of registered
     iPhone devices."

Nothing in this project is at fault. Everything up to that line worked.

## The rule, first-party

From Apple's own membership comparison page, fetched and read directly rather
than taken from a forum:

> "The number of test devices that can be registered to your account for each
> platform is limited to **3** and each expires after **7 days**."
>
> "The number of App IDs that can be registered your account at one time is
> limited to 10 and each expires after 7 days."
>
> "Provisioning profiles will expire 7 days from issuance..."
>
> — https://developer.apple.com/support/compare-memberships/

So: **3 device slots, each with its own rolling 7-day timer.** There is no
annual reset — that is a paid-Program mechanism. An Apple DTS engineer
(Quinn "The Eskimo!") gives the same answer on the developer forums in
August 2025 and confirms it unchanged in March 2026, and his stated workaround
is simply to wait.

His team has history — `com.spotify.client.3GAQP72Y5Z` from an earlier sideload
— so those slots are spent.

## Removing devices: no confirmed route for a free account

Free accounts cannot reach the device-management UI:
`developer.apple.com/account/resources/devices/list` answers *"This resource is
only for developers enrolled in a developer program."* The App Store Connect
API's device endpoints require paid enrolment and an API key.

**A correction I owe this file.** One research pass returned a promising lead:
fastlane's `spaceship` gem exposes `Device#enable!`/`disable!`, `PATCH
/v1/devices/{id}` with `status: DISABLED` frees a slot, and the API is
supposedly not gated by account tier — only the web UI is. It came with a
single hands-on report from one repository. A second pass searched the same
fastlane/spaceship, AltStore, SideStore and xtool trackers specifically and
found **no** such route working for free accounts, alongside Apple's own
position that none exists.

I nearly relayed the first as a plan. It is one unreplicated report against
first-party documentation, so it is written down here as a lead and **not** as
a route. If it is ever tested, it needs his Apple ID login and should be
treated as an experiment that will probably fail.

## Why the devices list is empty while the quota is full

    $ xtool ds devices list        -> empty, rc 0
    $ xtool ds certificates list   -> empty
    $ xtool ds identifiers list    -> com.spotify.client.3GAQP72Y5Z

**Not explained by any source, official or community.** The best available
guess is that expired-or-superseded registrations stop being returned by the
list call while still occupying a slot until the server-side timer clears —
Apple documents exactly that behaviour for *paid* accounts ("If you remove a
registered device from your account, it will continue to count against your
device limit"), but not for free ones. **That is an inference and is recorded
as one.**

The practical consequence is real, though: the empty list means xtool cannot
tell that a device is already registered, so it always tries to create one.

## The options, ranked

1. **A second free Apple ID.** A new Apple ID gets its own Personal Team with
   three empty slots, and registration works immediately. Free, legitimate, no
   waiting. The phone does not change iCloud accounts — only the machine doing
   the signing authenticates as the new ID, and the phone trusts the new
   developer on first launch. **His existing sideloads are unaffected**; they
   were signed by a different team and keep their own profiles.
2. **Wait.** Up to 7 days from the most recent registration for a slot to age
   out. Apple's own recommended answer, and free. Slow, and unhelpful tonight.
3. ~~Disable a device via the API~~ — see the correction above. A lead, not a
   plan.
4. **The $99 Program is not on the table.** He killed it deliberately. It is
   noted here only so nobody re-proposes it as the obvious fix.

## Something to know regardless of which is chosen

**The 7-day expiry applies to the app too.** Provisioning profiles expire a week
from issuance, which is the weekly re-sign he already accepted knowingly. It is
not extra bad news — it is the same cost, and it is why `sideload.sh` is
re-runnable.

---

## 2026-08-27 — resolved, and it was reading (2)

Checked against Apple directly, with his live token on archserver:

    $ xtool ds devices list
    - id: 25RYBYG6YU
      name: Bogdan
      platform: IOS
      udid: 00008130-001669590ABA001C
      device class: IPHONE
      status: ENABLED
      model: iPhone 15 Pro
      added date: 25/08/2026, 10:53 PM

    $ xtool ds certificates list
    - id: K3AQZFDBUU
      name: Apple Development: Bogdan Stamenović
      expiry: 25/08/2027, 10:43 PM

**The device is registered and ENABLED**, and the registration timestamp
(25 Aug 22:53) is the same minute the 403 was raised. So reading (2) above was
correct: the slot was never full. `devices list` was empty *at that moment*
because the registration had only just been created, and xtool, seeing nothing,
tried to create it a second time and was refused for duplicating it.

Two consequences:

- **The second Apple ID is not needed.** Option 1 in the ranking above should
  not be acted on. Nothing about the account has to change.
- **A re-sign will not hit this.** The device already exists, so the weekly
  `sideload.sh` re-run has no device to register.

Note the arithmetic while you are here: registered 25 Aug 22:53, profile expires
1 Sep 22:53. That is the 7-day clock, and it is measured from registration.
