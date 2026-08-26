# App plan — the SwiftUI rebuild

Status: **draft for approval, 2026-08-26.** This is the document the client is
written from, the way `SERVER-PLAN.md` is the document the daemon is written
from. Nothing here has been built yet.

The design is settled. Four concepts were judged (`DESIGN.md`, "Redesign
verdicts"):

- **Kinetic Prime** — *"basically perfect absolutely perfect."* Its tokens,
  layout, density, gestures and its one-progress-value scene change **are** the
  app.
- **Telemetry** — *"i like all the telemetry especially the one inside agents.
  I want that implemented absolutely."* Scoped by him on 2026-08-26: *"i dont
  want its rail on the agent pick screen. I want the specs when you are already
  inside the agent chat those are all i want."* **Telemetry's readouts live
  inside the agent channel and nowhere else.** §5 is built around that line.
- **Editorial's slam card** — its agree/kill transition only, rebuilt in Prime's
  shell. Spec at `docs/MOTION-SLAM-CARD.md`; rebuilt for SwiftUI in §9.
- Focus Pull and Cold Light are discarded and are not referenced again.

The prototypes are the normative reference for every number in §4 and §5:

```
scratchpad/concepts/v2-prime.html        the shell
scratchpad/concepts/v2-telemetry.html    the in-channel readouts
docs/MOTION-SLAM-CARD.md                 the commit transition
```

Where this document gives a constant, it was read out of one of those three
sources rather than invented. Where it changes one, it says so and why.

**The rule inherited from `SERVER-PLAN.md` §9.1, and the one that decides
arguments in this document: every animated quantity must encode a real number.
A readout with no honest source does not ship.**

---

## 0. Constraints that shape everything below

- **Swift 6.2 toolchain, and only 6.2.** The Darwin SDK is Xcode 26.2's
  (Apple Swift 6.2), and the Linux compiler must match it exactly; 6.3.3 fails
  with `this SDK is not supported by the compiler`. See `docs/BUILDING.md`.
  Nothing here may require a feature newer than Swift 6.2.
- `swift-tools-version: 6.2`, `.defaultIsolation(MainActor.self)` — already
  set. Keep it.
- **No third-party dependencies.** Bundled resources (a font file) are not
  dependencies; a package is.
- **Reinstalling is expensive.** Free provisioning, 7-day expiry, 3-device
  limit, no self-service removal. Consequence, and it is a hard architectural
  rule, not a preference: **anything the UI can show, enable, disable or label
  must be answerable by the server at runtime.** No hardcoded capability list,
  no hardcoded button label, no hardcoded disabled reason, no baked-in address.
- **Dark only. Expressive springs. Haptics sparingly. No sound** — no
  `AVAudio*`, no `.audioFeedback`, no system sound IDs, and Core Haptics runs
  with `playsHapticsOnly = true` so it cannot make one by accident.

---

## 1. What exists today, and what replaces it

Six files, ~1 100 lines. The toolchain proof worked; the app it proved it with
is being replaced almost entirely.

| Today | Becomes | Fate |
|---|---|---|
| `Model.swift` | `Wire/Wire.swift` | rewritten — new fields, `Moment` re-keyed on the global `seq` |
| `Link.swift` | `Wire/Link.swift` | kept in shape, extended to the §6 endpoint table |
| `Store.swift` | `Store/Fleet.swift` + `Store/Channel.swift` + `Store/Cache.swift` | **split** — this is where all three bugs live |
| `ContentView.swift` | `Shell/*` | deleted |
| `Server.swift` | `Settings/Server.swift` | kept nearly verbatim; it is correct |
| `HotlineCallApp.swift` | same | kept, extended with scene-phase handling |

`Server.swift` survives because its reasoning is right and still is: the address
is a setting rather than a constant, because an address baked into a binary he
re-signs weekly is an address he cannot change without a rebuild.

### 1.1 The three bugs, diagnosed against the current code

These are not fixed by being asserted. Each one is a consequence of a structural
choice, and the new architecture removes the structure rather than patching the
symptom.

**Bug 1 — "messages appear and disappear slowly; the feed never starts until
you send something."**

*Cause.* `Store.follow(_:)` is called from exactly two places: `send()` and
`answer()` (`Store.swift:79`, `Store.swift:58`). Nothing else ever starts a
feed. Open a channel and say nothing and there is no `Task` polling anything.
Compounding it, `refresh()` runs only from `ContentView`'s `.task { }` and
`.refreshable { }` (`ContentView.swift:36-37`), and `.task` fires once per
`Store` identity — which is stable for the whole foregrounded lifetime. So the
agent list and the waiting banner go stale on launch and stay stale.

*What prevents it.* **Feeds are owned by layer lifetime, not by the send path.**
`ChannelLayer` carries `.task(id: agentID) { await channel.run() }`; the
composer has no reference to the feed and no code path from `send` to `run`
exists to be forgotten. Independently, `Fleet` starts a `roster-events`
long-poll from `Shell`'s `.task` at launch and re-arms it on
`scenePhase == .active`, so the *list* is live before any channel is open at
all. The invariant, stated so it can be checked in review:

> The only thing that starts or stops a feed is a channel becoming, or ceasing
> to be, the foreground channel. The only thing that starts or stops the roster
> stream is the app becoming, or ceasing to be, active.

**Bug 2 — "opening a different agent's channel still shows the previous one's
messages."**

*Cause.* There are no channels. `Store` holds one `moments: [Moment]` array
(`Store.swift:12`) belonging to whichever conversation was last followed, and
the agent chip's action is `store.chosen = agent.name` and nothing else
(`ContentView.swift:117,120`). That changes where the *next* message goes; it
never swaps the transcript.

*What prevents it.* `moments` moves onto `Channel`, one instance per agent,
owned by `Fleet` in a `[AgentID: Channel]` map. There is no shared array left to
leak. Three further guards, in order of how loudly they fail:

1. `.task(id: agentID)` — SwiftUI cancels the previous task before starting the
   new one, so the old feed cannot deliver into a live view.
2. `/agents/feed` responds `{agent, events, cursor, closed}`. `Channel.apply`
   asserts `page.agent == self.name` and traps if not. Cross-talk becomes a
   loud precondition failure in a debug build rather than a silent wrong render.
3. The layer is keyed `.id(agentID)`, so no view state survives a switch.

**Bug 3 — "`Store.apply()`'s dedup eats repeated messages."**

*Cause.* `apply` drops any `.you` moment whose **text** matches one already
shown (`Store.swift:99-101`). Send "yes" twice and the second disappears. The
deeper cause: the optimistic local echo is given a fake identity —
`1_000_000 + moments.count` (`Store.swift:115`) — which can never equal the id
the server will assign, so identity had to be faked by comparing content, and
content is not unique.

*What prevents it.* **The optimistic bubble is never put in `moments` at all,
and no code path compares message text.** A send appends to a separate
`pending: [Pending]` array (main-actor view state, not wire data). The thread
renders `moments` followed by `pending`. When the feed delivers a `.you` event,
the head of `pending` is popped — FIFO, positional, content-blind. This phone is
the only writer of `you` events for this agent, so FIFO is sound. Two identical
sends produce two pending entries and two feed events and both survive.

A failed send flips its pending entry to `.failed(String)` with a retry
affordance instead of vanishing, which is the other half of the same bug: today
a send that throws leaves a bubble on screen that was never delivered.

The exact version of this needs one server field — see §11 — but the FIFO
version is correct without it and ships first.

---

## 2. Architecture

### 2.1 The view tree

There is no `NavigationStack`.

```
HotlineApp                                  @main
└─ RootView                                 owns Server; builds Link; .id(url)
   ├─ SetupView                             when no address is set
   └─ Shell                                 owns Fleet; owns every progress value
      ZStack, back to front:                and the atomic-presentation lock
      ├─ FleetLayer      z 10   the list, its own scroll, pull-to-refresh, pull-to-brief
      ├─ (scrim)         z 15   0…0.52 opacity, driven by nav
      ├─ ChannelLayer    z 20   one agent: instrument strip, thread, composer
      ├─ MapLayer        z 30   phases + recorder strip, pulled down like a blind
      ├─ SheetLayer      z 40   brief / control / purge — custom, in the motion language
      ├─ OverlayLayer    z 50   the flying title, the signal banner, the coach toast
      └─ SlamLayer       z 70   the commit card (§9). Above everything, always.
```

**Why not `NavigationStack`.** The approved list→channel transition is not a
push. It is an orchestrated disassembly — the list flying apart around the row
you chose, that row dissolving in place, its name lifting out and travelling to
the header, the thread materialising newest-first behind it, the composer rising
last — all driven by one progress value that a drag can scrub backwards and
forwards at whatever speed the thumb chooses. `NavigationStack` owns its own
transition and its own interactive pop; neither is reachable as a scalar we can
read. Using it would mean building the whole thing on top of a transition we
cannot see, in a container that fights us for the left-edge gesture.

What we give up, stated so nobody rediscovers it as a bug: the system back
swipe, large-title behaviour, `NavigationPath` state restoration, and automatic
keyboard avoidance in the pushed view. The first three are things this app does
not want. The fourth we implement (§4.7).

The system `.sheet` is still used, but only for Settings — a standard `Form`
where the platform's presentation is the right thing and no motion continuity is
claimed. Anything that participates in the motion language (brief a new agent,
the control sheet, the purge sheet) is a custom layer, so its spring is the same
spring as everything else.

### 2.2 The state model

Four objects. That is the whole thing.

```swift
@Observable final class Server            // where archserver is. UserDefaults-backed.
@Observable final class Fleet             // the roster, the roster stream, the channel map
@Observable final class Channel           // one agent: moments, pending, vitals, phases, its feed
nonisolated final class Link: Sendable    // HTTP. No state beyond a URLSession.
actor Cache                               // the on-disk copy
```

`@Observable` rather than `ObservableObject` throughout, because SwiftUI then
tracks exactly the properties each view reads: the instrument strip redrawing
must not invalidate the thread, and the thread appending must not invalidate the
fleet list.

**`Fleet`** holds:

```swift
private(set) var agents: [Agent]              // roster order as the server gave it
private(set) var order: [AgentID]             // display order: blocked pinned, then roster
private(set) var globalControls: [Capability] // from /health
private(set) var reachable: Reachability      // .live | .stale(since: Date, why: String)
private var channels: [AgentID: Channel]      // lazily created, never two for one agent
func channel(for id: AgentID) -> Channel      // the only way to get one
```

`Fleet` owns the roster stream and nothing else owns a network task except a
`Channel`. It is the single place that reconciles `historyGeneration` (§8.4) and
the single place that decides display order.

**`Channel`** holds:

```swift
let name: AgentID
private(set) var moments: [Moment]        // server truth, keyed by global seq
private(set) var pending: [Pending]       // optimistic echoes, never in `moments`
private(set) var cursor: Int              // highest seq applied
private(set) var generation: Int
private(set) var phases: [Phase]
private(set) var samples: SampleRing      // §5.4 — channel-scope only
private(set) var loading: Loading         // .cold | .refreshing | .streaming | .failed(String)
private var live: Task<Void, Never>?
private var holdback: [Moment]            // parked while an atomic presentation runs, §9.2
private var suspended: Bool
```

`Delivery` from the old model is gone. It conflated "the network is busy" with
"the agent is working", which are different facts with different sources: the
first is `Loading`, the second is `Agent.state` from the roster.

**Composer draft is not in the store.** It is `@State` in the composer view.
Bogdan's own instruction on this, quoted in both prototypes' fixtures: *"keep
the composer dumb."*

### 2.3 Where the network link lives

`RootView` builds one `Link` from `Server.url` and hands it to `Fleet`; `Fleet`
hands the same instance to every `Channel`. `Link` is a `nonisolated final class:
Sendable` with no mutable state, so it can be captured by any task without
ceremony. `RootView` carries `.id(url)` so changing the address tears down and
rebuilds the whole store rather than leaving half of it pointed at the old host
— the existing app already does this and it is right.

### 2.4 The local cache

Requirements: a channel must open with its history **already on screen**, before
any network call returns; the copy must survive relaunch; a purge must be able
to erase it exactly; and there must be a non-destructive way to reclaim the
space.

**Form: one append-only JSONL segment set per agent, plus a small header.**

```
Application Support/hotline/
  agents/<name>/head.json          {generation, oldestSeq, newestSeq, segments, bytes}
  agents/<name>/0001.jsonl         one JSON-encoded Moment per line
  agents/<name>/0002.jsonl         rotates at 512 KB, at most 4 kept
```

Appends are O(1) and crash-tolerant (a torn last line is dropped on read and the
history refetch fills the hole). A cold open reads the newest segment only,
which is bounded by construction. Purge is `removeItem(at: agentDir)`. Free up
space is `removeItem(at: hotlineDir)`.

**Why not SQLite.** It is available (`import SQLite3`, a system library, no
package). It is still the wrong answer here: it brings a schema, migrations,
statement lifetime management and a linker setting, in exchange for query
capability this cache does not need. The phone never queries — it reads the tail
and appends. The authoritative, indexed, paginated store already exists and is
on archserver (`SERVER-PLAN.md` §1). **The phone's copy is a cold-open
accelerator, not a database**, and building it as one would be a second source
of truth to keep honest.

Location is Application Support, not Caches, because the OS may evict Caches
under pressure and the entire point is that a channel opens in zero frames.
`isExcludedFromBackup = true`, because every byte of it is re-downloadable.

---

## 3. Concurrency

Per the Swift 6.2 model. The module is main-actor-by-default; the annotations
below are the exceptions, and each one has a reason at its definition site.

### 3.1 What is where

| Runs on | What | Why |
|---|---|---|
| **Main actor (default, unannotated)** | every `View`, `Fleet`, `Channel`, `Server`, the progress values, the sample ring, the composer, the slam-card sequencer | it is all UI-facing state; annotating each one would be noise |
| **`nonisolated`** | `Wire.swift` in full — `Agent`, `Vitals`, `Capability`, `Moment`, `Phase`, `CompactResult`, every page type | they are decoded off the main actor; a main-actor-isolated synthesised `Codable` conformance cannot be used from there. This is already true today and is the reason the current `Model.swift` says `nonisolated`. **Preserve it.** It is also simply the truthful annotation: pure wire data with no UI state |
| **`nonisolated`** | `Link` | none of it touches UI, and a transport should let the caller decide where it runs |
| **`nonisolated`** | `Sparkline`, `WaveShape`, `InsetReveal` and every other `Shape`; the `Stage` animatable modifier | SwiftUI calls `Shape.path(in:)` and `Animatable.animatableData` off the main actor. See 3.3 |
| **`actor`** | `Cache` | genuinely shared mutable state (file handles, the header index) that must not be on the main actor. This is the one place in the app where state moves off the main actor, and it is because of file I/O, not because of CPU |
| **`@concurrent`** | **nowhere in v1** | see 3.2 |

`Haptics` (§4.8) is a main-actor `final class` holding one `CHHapticEngine`.
Core Haptics' engine is not `Sendable` and its reset/stopped handlers arrive on
an arbitrary queue; those two closures are the only place in the app that uses
`MainActor.assumeIsolated` — they assert rather than hop, so a wrong-thread
delivery traps loudly instead of racing silently.

### 3.2 `@concurrent`, and why it is absent

The progression is main-actor → `async` → `@concurrent` → `actor`, and you do
not skip steps. This app's expensive work is:

- HTTP, which `URLSession.data(for:)` already offloads on our behalf. Marking
  our wrappers `@concurrent` would move only the `await` and buy nothing.
- Decoding. The largest single payload is a 200-event history page — hundreds of
  microseconds.
- File I/O, which is on the `Cache` actor already.
- Path building for the channel sparkline and the recorder waveform. A few
  hundred points, rebuilt only when the underlying samples change.

None of that is a hang. **`@concurrent` appears nowhere until Instruments shows
one**, and if it ever does, the two candidates in order are: decoding a history
page (move `JSONDecoder.decode` into a `@concurrent nonisolated func` on `Link`)
and building the recorder's full-session series (a `@concurrent` function
returning a `[CGPoint]` value). Both are trivially safe to move because their
inputs and outputs are `Sendable` values. Neither ships pre-emptively.

### 3.3 The places SwiftUI runs our code off the main actor

The signal is `@Sendable` in the API's signature. Three of them matter here:

**`Shape.path(in:)`.** Every instrument mark is a `Shape`, so every instrument
mark is `nonisolated` and can hold only value data:

```swift
nonisolated struct Sparkline: Shape {
    var samples: [Double]        // already decimated, already Sendable
    var ceiling: Double
    func path(in rect: CGRect) -> Path { … }
}
```

Consequence, and it is load-bearing for §5: **a mark can never be handed a
`Channel` or a `Fleet`.** The view computes the decimated `[Double]` on the main
actor and passes it by value. That is also why `Sample` and `SampleRing` are
value types.

**`Animatable.animatableData`.** The scene-change modifier and the slam card's
reveal mask must conform to `Animatable` for their nonlinear windows to be
evaluated per frame (§4.3, §9.4). Under main-actor-by-default, an isolated
`animatableData` cannot satisfy the protocol's nonisolated requirement. The
pattern is:

```swift
nonisolated struct Stage: ViewModifier, Animatable {
    var e: Double
    var animatableData: Double { get { e } set { e = newValue } }
    @MainActor func body(content: Content) -> some View { … }   // View is @MainActor
}
```

The type is `nonisolated` so `animatableData` satisfies the requirement; `body`
is re-annotated because building a `View` is main-actor work. Everything `body`
needs must arrive as a stored value on the modifier — it cannot reach out to
main-actor state.

**`onGeometryChange(for:of:action:)`** is used once, to measure the row title for
the hero flight (§4.4). Its `of:` transform is `@Sendable` and must capture
nothing; its `action:` is main-actor and is where the measurement is stored.

### 3.4 The tasks

Five kinds, and no others.

**1. The roster stream.** One unstructured `Task`, owned by `Fleet`, started
from `Shell`'s `.task { }` and re-armed on `scenePhase == .active`.

```
loop while !Task.isCancelled:
    tick = await link.rosterEvents(since: cursor, wait: waitSeconds)   // long poll
    roster = await link.agents()                                       // one POST
    apply(roster)          // reconcile generations, order, controls, vitals
```

`waitSeconds` is **5 while a channel is open, 25 otherwise.** That is not a
performance tweak: it is the refresh rate of the in-channel instrument strip
(§5.4), and it is the only knob that decides whether the readouts feel live. On
the fleet list nothing is sampled, so the long wait is correct there and costs
nothing. One constant, `Fleet.sampleWait`, one place to change it.

**2. The channel feed.** One structured sequence inside one `Task`, owned by
`ChannelLayer`'s `.task(id:)`. This is the hard-refresh-then-stream seam and its
order is the whole point:

```
0.  paint from cache            synchronous, before this task starts
1.  if roster generation != cached generation: drop the cache for this agent
2.  page = await link.history(agent:, before: nil, limit: 200)
    replace moments with page.events        ← authoritative for the visible window
    cursor = page.newestSeq
3.  loop while !Task.isCancelled:
        page = await link.feed(agent:, since: cursor, wait: 25)
        append page.events (or park them in holdback, §9.2); cursor = max(cursor, page.cursor)
        append to cache — always, even when parked
        on error: backoff 250 ms ×2 to a 5 s ceiling, reset on success
```

One task, because the steps must happen in order — that is the rule for
end-to-end operations, and it is also the only way to guarantee the seam has no
hole and no duplicate. `SERVER-PLAN.md` §8 asserts the server-side property this
depends on: `history(before: nil, limit: k)` and `since(cursor: newestSeq)`
return disjoint sets whose union is everything. Because the store now uses one
global `AUTOINCREMENT seq`, "no gap, no duplicate" is a property of `>` on a
primary key rather than something this client reconciles.

Step 2 **replaces** rather than merges, so a purge on the server cannot leave
stale rows on the phone. Older history is paged in backwards on demand (pull
down at the top of the thread) with `before: oldestSeq`.

Cancellation is cooperative: the loop checks `Task.isCancelled`, and the
long-poll's suspension is cancelled by `URLSession`'s own task cancellation via
the async `data(for:)` bridge. There is no `withTaskCancellationHandler` and no
detached task anywhere in this app.

**3. UI-event tasks.** `Task { await store.send(text) }` from a button action,
and the same for each control dispatch. Unstructured because the lifetime is the
operation, not a scope. Each one is short and self-cancelling.

**4. Cache writes.** `await cache.append(agent:, moments:)` from inside the feed
loop's task, hopping to the `Cache` actor. Batched per feed page, never per
moment.

**5. The slam-card sequencer.** One main-actor `Task` per run, holding the
atomic lock, awaiting `Task.sleep` between beats. §9.3.

**No `Task.detached` anywhere.** It inherits nothing — not isolation, not
priority, not task-locals — and there is no work here that wants that.

### 3.5 Sendability

Everything that crosses an isolation boundary is a value type whose storage is
`Sendable`: `Agent`, `Moment`, `Vitals`, `Capability`, `Sample`, `[Sample]`.
`Fleet` and `Channel` are `@Observable` main-actor classes and are therefore
implicitly `Sendable` — but they are never sent anywhere, and the marks in §5
are structurally prevented from receiving one (3.3). `@unchecked Sendable` and
`nonisolated(unsafe)` appear nowhere. If a data-race diagnostic shows up during
the build, the fix order is: stop sharing it → make it a value → isolate it —
in that order, before anything else is considered.

---

## 4. The motion system

This is the heart of the rebuild. It is specified in more detail than the rest
because it is the part that was judged, and because "expressive springs" is a
fixed product decision that a default `.snappy` does not satisfy.

### 4.1 Tokens

Straight from `v2-prime.html`; Telemetry adds `ink5`, `sig12`, `sig06` and those
are included because its in-channel marks need them. One `Theme` enum, no
semantic colours, no light variant, `.preferredColorScheme(.dark)` at the root.

| token | value | used for |
|---|---|---|
| `bg` | `#08080A` | the ground |
| `bgLift` | `#0E0E12` | the map layer |
| `surf` | `#131318` | cards, sheets |
| `surf2` | `#1B1B21` | his own message bubbles |
| `line` | white 6.5% | hairlines |
| `line2` | white 11% | chips, borders |
| `ink` | `#F4F4F6` | primary text |
| `ink2` / `ink3` / `ink4` / `ink5` | ink at 56 / 30 / 14 / 7 % | descending |
| `sig` | `#FF4A1E` | the one accent — blocked, and destructive |
| `sigLift` | `#FFB09A` | text on a blocked row |
| `sig20/12/10/06` | sig at 20/12/10/6 % | washes, fills |

Radii: card 14, bubble 18, pill 999. `@ScaledMetric` for row height and the
instrument strip (§4.9).

**Type.** Bundle **Geist** (variable, OFL) as a package resource with its
`OFL.txt`. A bundled font file is a resource, not a dependency. The entire look
rests on its tracking and its tabular figures; SF Pro at the same sizes reads
noticeably wider and the wordmark loses its character. If Bogdan would rather
not bundle it, the fallback is SF with the tracking table below applied
unchanged — the density holds.

**Never `.monospaced()`. Always `.monospacedDigit()`.** Telemetry's rule: no
monospace anywhere; digits are tabular Geist, in columns. Every readout, clock,
count and timestamp gets `.monospacedDigit()` so numbers do not jitter as they
change.

| role | size / weight | tracking |
|---|---|---|
| wordmark | 34 / 600 | −0.035 em (−1.19 pt) |
| screen title | 28 / 600 | −0.032 em (−0.90 pt) |
| slam word | 44 / 700 | animated, +0.04 em → −0.055 em (§9.4) |
| row name | 17 / 600 | −0.018 em (−0.31 pt) |
| message body | 15.5 / 400, line height 1.42 | −0.012 em |
| row subtitle | 13.5 / 400 | −0.008 em |
| cell value | 15 / 600 | −0.025 em |
| label (uppercase) | 9.5–11 / 600 | +0.09 to +0.15 em |

### 4.2 The springs

`v2-prime.html` uses a mass-spring-damper integrator with `m = 1`, integrated at
a fixed 1/240 s substep. SwiftUI's `interpolatingSpring(mass:stiffness:damping:)`
is **the same model with the same parameterisation**, so this is an exact port
with no translation loss — pass `k` and `c` through unchanged.

| name | stiffness | damping | ω₀ (rad/s) | ζ | used for |
|---|---|---|---|---|---|
| `snap` | 380 | 32 | 19.49 | 0.821 | row snap-back, commit, every FLIP |
| `glide` | 220 | 30 | 14.83 | 1.011 | the forward scene change, scroll settle |
| `navBack` | 300 | 34 | 17.32 | 0.981 | the reverse: same path, ~30 % faster |
| `settle` | 520 | 46 | 22.80 | 1.009 | small offsets, press states |
| `float` | 120 | 18 | 10.95 | 0.822 | the rows parting: slow, heavy |
| `climb` | 340 | 26 | 18.44 | 0.705 | the blocked row: fast, slight overshoot |
| `enter` | 180 | 26 | 13.42 | 0.969 | staged entrances |
| `whip` | 700 | 34 | 26.46 | 0.643 | the one bouncy spring — answer commit only |
| `meter` | 260 | 26 | 16.13 | 0.806 | the in-channel readouts |

```swift
extension Animation {
    static let snap = Animation.interpolatingSpring(mass: 1, stiffness: 380, damping: 32)
    …
}
```

The slam card (§9) is the one part of the app that is **not** spring-driven: its
source is authored entirely in cubic-bézier timing curves and its beats are
timed against each other to the millisecond. Those are ported as
`.timingCurve(...)`, not re-expressed as springs. Mixing the two would destroy
the overtake and the held beat, which are the whole point of it.

**The `climb` / `float` pair is load-bearing and must not be collapsed into one
spring.** The blocked row climbs at ω 18.4 while the rows it passes part at
ω 11.0. The overtake — watching it jump the queue rather than the queue tidily
re-sorting — is the whole point of the arrival choreography (§4.6). A single
system spring for both destroys it, silently and un-reportably.

`navBack` is deliberately faster than `glide`: entering a scene is a deliberate
act and can be cinematic; leaving it is the system answering, and a slow exit
reads as lag. The same asymmetry governs every enter/exit pair in this document
(the blocked wash enters over 640 ms and leaves over 300; the slam card's hold
fills over 1 500 ms and cancels over 220).

### 4.3 The scene change

One `Double`, `nav ∈ [0, 1]`, held as `@State` in `Shell`. Everything in the
list→channel transition is a pure function of it. Nothing has its own timeline,
because a second timeline is a thing that can drift out of sync with the first.

**How it is read.** Each layer is wrapped in a `nonisolated struct ... :
ViewModifier, Animatable` whose `animatableData` is `nav`. SwiftUI then
interpolates `nav` itself, frame by frame, and re-evaluates `body` at each
value — which is what makes the nonlinear staging windows below survive. (If the
modifier were not `Animatable`, SwiftUI would interpolate each derived opacity
and offset linearly between its endpoints and every stagger would flatten out.
That failure mode is silent and looks merely "less good", so it is worth
knowing what it looks like.)

**The window function**, ported verbatim:

```swift
func win(_ e: Double, _ start: Double, _ span: Double) -> Double {
    let t = min(max((e - start) / span, 0), 1)
    return t * t * (3 - 2 * t)          // smoothstep
}
```

Smoothstep softens the ends of each element's window. **The master `nav` stays
linear**, so a drag-back tracks the finger 1:1.

**The staging table.** `MO` is 1 normally and 0 under Reduce Motion; it
multiplies every positional term so the staging survives as pure opacity.

| element | expression |
|---|---|
| fleet layer | `offsetY = −10·e·MO`, `scale = 1 − 0.055·e·MO`, `opacity = 1 − 0.45·e`, origin 50 % / 40 % |
| scrim | `opacity = 0.52·e` |
| hero row (`d == 0`) | `p = win(e, 0, 0.30)`; `opacity = 1 − p`; `blur = round(p·4)` pt. It does not travel — it dissolves where it stands while its name is lifted out of it |
| every other row | `p = win(e, |d|·0.042, 0.5)`; `offsetY += sign(d)·p·(118 + |d|·44)·MO`; `opacity = 1 − p` |
| channel layer | `opacity = clamp(e/0.42, 0, 1)`; `offsetY = (1−e)·30·MO`; `scale = 1 − (1−e)·0.028·MO`; hit-testing enabled at `e > 0.55` |
| channel accent rule | `scaleX = win(e, 0.06, 0.5)`, origin left |
| back chevron | `stage(win(e, 0.28, 0.42))` |
| phase chip | `stage(win(e, 0.42, 0.42))` |
| state line | `stage(win(e, 0.48, 0.42))` |
| instrument strip cells, index *i* | `stage(win(e, 0.44 + i·0.026, 0.42))` |
| composer | `cp = win(e, 0.36, 0.5)`; `opacity = cp`; `offsetY = (1−cp)·74·MO` |
| message *k* from the bottom (0 = newest, arrives first) | `q = win(e, 0.24 + k·0.030, 0.44)`; `opacity = q`; `offsetY = (1−q)·28·MO`; `blur = round((1−q)·4)` |

where `stage(p) = (opacity: p, offsetY: (1−p)·15·MO)`.

**Blur is quantised to whole points** (`round`). A blur radius that changes every
frame forces a re-rasterisation every frame; quantised, the layer re-rasterises
about five times across the transition. This matters on a phone and it is free.

**Only the visible tail of the thread is staged.** Messages beyond the first
screenful are excluded from the stagger — `k` is capped at 12 — so the window
for the newest message does not compress to nothing on a 400-message channel.

### 4.4 The hero title

The agent's name is one object travelling between two screens, not two labels
crossfading.

- Measure the row's name rectangle in untransformed list space with
  `onGeometryChange(for: CGRect.self)` against a named coordinate space on the
  frame. Re-measure at the start of *every* transition, forward and backward,
  because the row may have moved since (reorder, unpin, scroll).
- The travelling copy lives in `OverlayLayer` at z 55.
- `ef = clamp(e/0.82, 0, 1)` — the shared element leads. It arrives before the
  world assembles.
- `position = lerp(rowFrame.origin, (24, 98), ef)`, `scale = lerp(1, 28/17, ef)`.
- **Tracking is interpolated too, and divided by the scale**, or it grows with
  the glyphs and the header title reads loose:
  `tracking = lerp(17·(−0.018), 28·(−0.032), ef) / scale`
  = `lerp(−0.306, −0.896, ef) / scale` points.
  This is the same animated-tracking risk the slam card names; verify it the
  same way (§9.6).
- Handover: the travelling copy hides at `e > 0.88` and the real title's opacity
  goes to 1 at the same instant. The row's own name is hidden for `e > 0.008`.
- Under Reduce Motion the flight does not happen: the travelling copy stays
  hidden and the header title fades in over `clamp((e − 0.3)/0.4, 0, 1)`.

`matchedGeometryEffect` is not used **anywhere in this app**: here because it
owns its own interpolation and cannot be scrubbed by an external progress value,
and in the slam card because there is no shared geometry to preserve (§9.1).

### 4.5 Scrubbing, and retargeting mid-flight

**Forward.** Tapping a row: measure, prepare the scene, then
`withAnimation(.glide) { nav = 1 }`.

**Backward, by drag.** A `DragGesture(minimumDistance: 6)` on the channel layer,
gated to the left 44 pt strip and to `nav > 0.5`:

- `.onChanged` — `nav = clamp(navAtStart − translation.width / width, 0, 1)`,
  **written with no animation.** The finger owns it; 1:1.
- `.onEnded` — decide, then hand over velocity:

```swift
let vProgress = -value.velocity.width / width            // progress per second
let predicted = nav + project(vProgress)                 // where the fling is going
let target: Double = predicted < 0.55 ? 0 : 1
let distance = target - nav
let v0 = abs(distance) < 1e-4 ? 0 : vProgress / distance // normalise: see below
withAnimation(.interpolatingSpring(mass: 1,
                                   stiffness: target == 0 ? 300 : 220,
                                   damping:   target == 0 ? 34  : 30,
                                   initialVelocity: v0)) { nav = target }
```

Two details that are the difference between this feeling right and feeling
approximately right:

1. **`initialVelocity` on `interpolatingSpring` is normalised by the distance
   being animated**, not an absolute rate. Passing the raw finger velocity makes
   a short throw explode and a long throw feel dead. `v0 = vProgress / (target −
   nav)`, guarded against the divide.
2. **Use `value.velocity`** (iOS 17) rather than differencing translations, and
   `project(v) = (v/1000)·0.998/(1 − 0.998) = v·0.499` for the decision — the
   same exponential-decay projection the system uses for scroll deceleration, so
   a fling here decides at the same threshold a fling anywhere else on the phone
   does.

**Retargeting mid-flight.** `interpolatingSpring` is velocity-preserving and
additive: a second `withAnimation` to a new target while the first is running
continues from the current position *and* the current velocity, which is exactly
the property the prototype gets by integrating from its presentation value. That
covers the real case — tap a row and immediately swipe back before the open
transition has landed. A drag taking over mid-flight is not a retarget at all:
the `.onChanged` write is unanimated, which cancels the running animation and
hands position to the finger, and velocity there is irrelevant because the
finger supplies it.

**If this misbehaves on device**, the named fallback is to port the integrator:
an `@Observable final class SpringValue { var k, c, value, target, velocity }`
stepped from a `TimelineView(.animation)` at display rate, with `nav` becoming a
plain `Double` that every layer reads. The constants in §4.2 transfer unchanged.
Cost: we own the tick and SwiftUI re-evaluates every reading view each frame.
The trigger to switch is one of: a visible discontinuity on drag→release→drag,
or staging windows that visibly linearize. Do not switch pre-emptively.

**Every scrubbable seam in the app uses this same shape**, with its own progress
value: `nav` (list↔channel), `map` (channel↔map, `dy/height·1.35`, opens at
`p > 0.04`, commits at `0.42`), `sheet` (0…330 pt), `scrub` (the recorder
cursor), `window` (the channel sparkline's span). Five values, one mechanism.
The slam card is deliberately outside this system — see §9.2.

### 4.6 The blocked-agent arrival

An agent blocks. Nobody tapped anything. This is the app's most important
animation because it is the one moment where it is telling him something rather
than answering him. **It is entirely Kinetic Prime's**, unaffected by the
telemetry scoping.

Trigger: a roster tick in which an agent's `blocked` goes false→true. **The
choreography is driven from the roster stream, not from a channel**, so it fires
whether or not that agent has ever been opened.

Six beats. Each is a real state change; the timings stage them so the order the
news travels in is legible rather than arriving as one jump.

| t | beat |
|---|---|
| **0 ms** | The dot switches to `blocked`. The header's accent rule sweeps: `scaleX` 0→1 from the left over the first 34 % of 1 500 ms, then the origin flips to the right and it collapses to 0. Haptic: one `.impact(weight: .medium)`. |
| **140 ms** | *The row says it in words.* The subtitle blur-crossfades to the question; the timestamp becomes "now"; the `NEEDS YOU` tag rises (opacity + 5 pt, 420 ms `ease-cine`, 220 ms delay). |
| **320 ms** | *The row becomes the thing it is.* The `sig10` wash wipes across it left→right (`clipShape` inset animated over 640 ms on enter, 300 ms on exit); the 2 pt pin bar reveals (`scaleY` 0→1, 520 ms, 120 ms delay) and its core begins a 2.9 s breathe; the row grows 88→116 pt on `climb`. |
| **320 ms** | *And it climbs.* The mover goes to `climb`; every other row goes to `float` with a delay that propagates outward from it — rows above `min(−d, 8)·26 ms`, rows below `min(d, 8)·14 ms`. The mover is lifted off the plane for the duration: z above the others, a `0 18 38 −14 / 92 %` shadow, `scale(1 + 0.014·lift)` where `lift` springs 0→1 on `enter`, back to 0 on `settle` at +500 ms, and the lift class is dropped at +860 ms. A row that climbs past other rows has to be *above* them or the pass reads as a rendering glitch. |
| **820 ms** | The fleet counts catch up, by blur-crossfade. |
| **980 ms** | *The news finds him.* **If the fleet layer is the visible one:** a coach toast, `<b>name</b> is blocked — pinned above the fleet`. **If he is in a channel or the map:** Telemetry's signal banner drops from the top (`snap`, from −140 to +8) carrying the agent, the question and a blocked clock that is already running. Tap navigates to it; swipe up dismisses; it auto-hides at 8 s. |

That last split is the one thing the merge adds: Prime assumes he is looking at
the list, Telemetry assumes he is not. Both are true at different times, so the
beat branches on which layer is visible. The banner is chrome, not a row
readout, so it survives the telemetry scoping.

**Unblocking** runs the same beats in reverse on the faster curves: the wash
retracts over 300 ms, the pin drops on `snap`, the row shrinks to 88 pt, and the
re-sort delays halve to `min(|d|, 8)·18 ms`. Enter is deliberate; exit is the
system responding.

**Blur-crossfade** (`blurSwap`) is one reusable component: out over 190 ms
(opacity→0, blur 4 pt, offset −5), swap the string, in from +5 over 220 ms.
Applied to every text that changes meaning under his eyes — subtitles, the
channel state line, the fleet counts. Two states must never sit legibly on top
of each other, and a hard cut looks broken. For pure digits use
`.contentTransition(.numericText())` instead, which does the same job per glyph.
Never animate a no-op: guard on the string actually differing.

**No arrival choreography runs while the slam card holds the lock.** It is
queued and fires on release (§9.2).

### 4.7 Gestures

Prime arbitrates row-drag against scroll inside **one** recognizer per surface,
with an 8 pt hysteresis and an axis lock. SwiftUI's `ScrollView` cannot be made
to do that: a per-row `DragGesture` and the scroll view fight over the ambiguous
first few points and the scroll view usually wins.

**Decision: the three scrolling surfaces are custom.** Rows are absolutely
placed in a `ZStack` with `.offset(y:)` driven by one scroll value; one
`DragGesture` on the viewport does the arbitration.

What this buys, and none of it is reachable otherwise:

- row-drag vs. scroll arbitration in one recognizer,
- pull past the bottom to brief a new agent,
- pull down past the top with its own meaning per surface,
- rows whose *order and height* animate independently of the scroll,
- the scene change reading row positions directly.

What it costs, stated once: we implement rubber-banding, momentum, and
keyboard-avoidance ourselves, and we lose `ScrollView`'s free accessibility
scrolling — so §4.9's VoiceOver rules are not optional. If the custom list
proves unstable on device the degradation path is a `ScrollView` with
`.swipeActions`, which loses the pull-up-to-brief and the fling-to-commit. That
is a real loss, not a graceful one.

**The formulas**, ported:

```swift
func rubber(_ over: Double, _ dim: Double, _ c: Double = 0.55) -> Double {
    (over * dim * c) / (dim + c * abs(over))
}
```

- Axis lock: no axis until `hypot(dx, dy) ≥ 8`, then lock to the larger and keep
  it for the gesture.
- Overscroll: rubber-banded with `c = 0.62` against the screen height.
- Release inside bounds: `to(clamp(scroll + project(vy), min, 0), vy)` on
  `glide`. Release outside bounds: `to(clamp(scroll, min, 0), vy·0.25)` on
  `float`.

**One meaning per gesture per surface.** This is stated as a table because the
two concepts assigned different meanings to the same pull and only one can win:

| surface | pull past the top | pull past the bottom |
|---|---|---|
| fleet list | **hard refresh** — roster + `/health`, with a chip that reads `REFRESH` and then the age of the data | **brief a new agent** (§7.1) |
| channel thread | **load older history** — `before: oldestSeq`, 200 at a time | nothing (it is already at the newest) |
| map timeline | nothing | nothing — it snaps phase to phase |

The sparkline's **window** is scrubbed on the sparkline itself (§5.5), not by a
pull, precisely so it does not collide with any of the above.

**Row swipe.** Limits: left −148 pt (−132 if the agent is dead), right +118 pt.

| condition on the projected end | outcome |
|---|---|
| `end < −lim·0.62` | rest open at `−lim` (the controls stay revealed) |
| `end < −lim − 74` or (`vx < −1100` and `x < −60`) | **fire `stop`**, snap to 0 |
| `end > 74` | rest open at `+118` |
| `end > 118 + 66` or (`vx > 1100` and `x > 50`) | **fire `retask`/`resume`**, snap to 0 |

**A fling only ever commits the reversible action. `kill` must be tapped**, and
then held (§9.5). This is the gesture-level half of §7's rule that kill gets a
confirmation and stop does not.

**The left 44 pt strip belongs to the back gesture and nothing else.** The
channel's own scroll recognizer filters out any touch starting there. The back
chevron sits inside that strip, so the back recognizer has to answer for taps on
itself — a chevron that swallows its own tap because an ancestor holds the
pointer capture is the classic version of this bug.

**Fling-to-send.** Prime's composer throws the message rather than clicking it:
drag the send knob upward, a ghost bubble follows with `x·0.55`, rotation
`clamp(dx·0.05, ±9)°` and a scale that grows with height; release above −110 pt
or faster than −420 pt/s commits, and the real bubble takes the velocity the
finger gave it through a FLIP from the ghost's frame. **Tapping send also
works** and does the same thing without the throw — the gesture is the delight,
not the only path. This is the only FLIP left in the app (§10).

### 4.8 Haptics

Two mechanisms, because two are genuinely needed.

**`.sensoryFeedback(_:trigger:)`** for everything single-pulse — declarative,
main-actor, no generator lifetime to manage. A global 90 ms rate limit (Prime's
`lastBuzz`) wraps every call site, because `.sensoryFeedback` fires on every
trigger change and a detent crossed during a fast scrub will fire twenty times.

| event | feedback |
|---|---|
| detent crossed (window scrub, phase boundary, answer-card threshold) | `.selection` |
| control committed (stop / retask / resume / compact) | `.impact(weight: .medium)` |
| blocked arrival | `.impact(weight: .medium)`, once |
| hold-to-fill press begins | `.impact(weight: .light)` |
| everything else | nothing |

**Core Haptics** for the slam card's two multi-pulse patterns, which
`UIImpactFeedbackGenerator` cannot express — it only produces single canned
pulses. One lazily-created `CHHapticEngine`, kept alive for the app's lifetime,
`playsHapticsOnly = true`, with reset and stopped handlers that restart it.
Patterns are discrete `.hapticTransient` events at explicit `relativeTime`
offsets:

| pattern | events (relativeTime s, intensity, sharpness) | used for |
|---|---|---|
| answer `[10, 40, 18]` | (0.000, 0.55, 0.5), (0.050, 0.85, 0.7) | the answer slam card |
| kill `[18, 60, 18, 60, 26]` | (0.000, 0.75, 0.6), (0.078, 0.75, 0.6), (0.156, 1.00, 0.8) | the kill slam card |

`CHHapticEngine.capabilitiesForHardware().supportsHaptics` is checked once; if
false, both patterns degrade to a single `.impact(weight: .heavy)` and nothing
else changes.

**No sound.** Not a ring, not a tick, not a send whoosh. There is no audio code
in this app, `AVFoundation` is not imported, and the haptic engine is
constrained so it cannot produce one.

### 4.9 Reduced motion, Dynamic Type, VoiceOver

**Reduce Motion** (`@Environment(\.accessibilityReduceMotion)`) follows one
principle everywhere in this app, taken from the slam card's source and applied
generally:

> **Keep the sequence. Strip the direction. Compress 2.5–3×. Remove the
> stagger.**

Concretely: `MO = 0`, which zeroes every positional term while leaving opacity
staging intact; every per-index delay goes to zero; every duration is multiplied
by roughly 0.35–0.40; and **sequenced beats still happen in order** — the beats
in §4.6 and §9.3 depend on each other's state and firing them in one tick makes
the sequence read wrong as well as look wrong. Looping decoration (the pin
breathe, the typing dots, the blocked ring) stops entirely. §9.7 gives the slam
card's exact reduced-motion table.

**Dynamic Type.** Row height and the instrument strip use `@ScaledMetric`. At
`.accessibility1` and above the channel's sparkline is dropped and the strip
reflows from a row of cells to a two-column grid — the numbers all survive, the
graph does not. This is a deliberate cut, not a clip: a 30 pt-tall sparkline
under 34 pt text is noise.

**VoiceOver.** Each list row is one element with a composed label —
`"hotline-ios, blocked 4 minutes, needs you"`. In the channel, the instrument
strip is one element reading all its cells in order, and the sparkline is
`.accessibilityHidden(true)` because its content is the `OUTPUT` cell. Every
capability is exposed as an `.accessibilityAction(named:)` on the row, so the
swipe is never the only route to a control. The custom scroll surfaces implement
`.accessibilityScrollAction(_:)`, since they do not get it for free. The slam
card posts an `.announcement` of its word and sub-line when it lands and takes
`.accessibilityFocus` for its duration.

---

## 5. Telemetry — inside the channel only

### 5.0 The split, stated so nobody rebuilds it wrong later

Bogdan, 2026-08-26: *"i dont want its rail on the agent pick screen. I want the
specs when you are already inside the agent chat those are all i want."*

| surface | what it shows |
|---|---|
| **the agent list** | **pure Kinetic Prime. No telemetry of any kind.** No per-row rail, no per-row sparkline, no tool-call flash on the dot, no fleet aggregate, no fleet meter |
| **the agent channel** | **all of Telemetry's readouts** — throughput, tool cadence, the sparkline and its window, time blocked, phase progress, context used |
| **the map / recorder** | the strip, the waveform, tool ticks, the blocked span, and the bidirectional lock to the phase timeline |

If a future change wants a number on a list row, it is a new decision and it
starts from this line, not from an inference.

### 5.1 What the list row shows

Kinetic Prime's row, unchanged. Named explicitly so the boundary above is
checkable:

| element | content | source |
|---|---|---|
| pin bar | 2 pt `sig` bar at the left edge, **blocked rows only**, `scaleY` reveal then a 2.9 s breathe | `blocked` |
| status dot | 8 pt. `live` = solid ink with a 3.6 s pulse. `busy` = ink at 42 % with a 1.15 s pulse and an expanding ring. `blocked` = `sig` with a 1.7 s pulse and a ring. `dead` = a hollow 1.4 pt ring, **still** | `state` |
| name | 17 / 600, −0.018 em | `Agent.name` |
| `NEEDS YOU` tag | 9.5 / 700 uppercase `sig`, blocked only | `blocked` |
| relative time | right-aligned, tabular | `lastToolAt`, else `declaredAt` |
| subtitle | one line, ellipsised. Blocked: the question in `sigLift`. Dead: the `deadReason` | the newest event's text, or `deadReason` |
| tint wash | `sig10` gradient wiping in from the left, blocked only | `blocked` |
| row height | 88 pt, 116 pt when blocked | — |

**The dot's pulse is a categorical encoding, not a quantity.** Which rate you
see tells you which state the agent is in — 3.6 s live, 1.15 s busy, 1.7 s
blocked, still when dead — and that mapping is real data. It does not claim to
be a rate of anything. Inside the channel the same mark means something
different and finer: one flash per real tool call (§5.3). Two surfaces, two
honest encodings, and neither is a decorative loop.

**A dead agent is still.** No pulse, no ring, no breathe. `SERVER-PLAN.md` §9.2
states this as a correctness requirement on the data rather than a styling note,
and it is enforced in the mark itself: `state == .dead` short-circuits every
animation path.

### 5.2 The wire

```swift
nonisolated struct Vitals: Codable, Sendable, Hashable {
    let tokensPerSec: Double     // characters-derived, see SERVER-PLAN 9.2
    let toolsPerMin: Double
    let lastToolAt: Double?
    let blockedFor: Double?      // seconds, nil when not blocked
    let contextUsed: Double?     // 0…1 from statusLine used_percentage/100; nil = not yet sampled
}
```

`Agent` carries one `Vitals?` plus `contextAvailable: Bool` (§11).

**`tokensPerSec` is labelled `ch/s`, not `tok/s`.** `SERVER-PLAN.md` §9.2 is
explicit that it is characters, not a tokenizer count, and that it must never
read as a billing figure. Telemetry's prototype says `tok/s` because it was
drawing an invented number. Ours is real and approximate, so it gets the unit
that is true. The column header stays `OUTPUT`.

### 5.3 The instrument strip

Directly under the agent name and its state line, above the thread. Telemetry's
four cells, its 2 pt context bar, and — because the fleet meter's screen is gone
— its sparkline, brought down to channel scope.

```
 OUTPUT        CONTEXT       TOOLS         BLOCKED
 46 ch/s       32 %          4.2 /min      4:12
 ────────────────────────────────────────────────
 ╭──╮   ╭─╮        ╭────╮                        ← 342×30 sparkline
 ▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  ← 2 pt context bar
```

| cell | source | resolution | notes |
|---|---|---|---|
| `OUTPUT` | `vitals.tokensPerSec` | roster tick (5 s while a channel is open) | unit `ch/s` |
| `CONTEXT` | `vitals.contextUsed × 100`, integer percent | roster tick | three states, §5.6 |
| `TOOLS` | `vitals.toolsPerMin` | roster tick | exact |
| `BLOCKED` / `ELAPSED` | `vitals.blockedFor` when blocked; otherwise `now − declaredAt` | ticks locally every second | the label swaps with the state |
| sparkline | the channel's own `SampleRing` | see §5.4 | window scrubbed on itself, §5.5 |
| context bar | `vitals.contextUsed`, `sig` above 85 % | roster tick | animates on `meter` |

Every value change animates on `meter` (ω 16.1, ζ 0.81) rather than snapping —
a readout that jumps reads as a refresh, a readout that moves reads as a
measurement. Digits use `.contentTransition(.numericText())`.

**The tool dot in the channel** — the small mark beside the state line — flashes
once per real `tool` event on the feed: opacity 0.30→1 and scale 1→1.5 over
70 ms in, 400 ms out. **The feed carries every tool call, so this is exact**;
this is the readout that could not be honest on the list and is honest here.

**Tool rows in the thread** carry the tool name, the ≈200-character summary the
server stores, and a duration bar of width
`clamp(log10(1+s)/log10(61), 0, 1)·44 + 3` pt — **only if `duration_ms` reaches
the wire** (§11). Without it, the row renders with no bar, never a guessed one.
`via_subagent` rows are dimmed and indented, per `SERVER-PLAN.md` §2.

**The decision card's cost line** — *"Idle since 09:57 · 4:12 of wall clock
burned"* — is `blockedFor`, ticking live. Exact.

### 5.4 Where the samples come from

Two sources, and conflating them would be a lie:

- **`Vitals` on the roster**, appended to the open channel's `SampleRing` once
  per roster wake (≤5 s while a channel is open). This drives the four cells and
  the context bar.
- **The channel's own feed**, which carries every assistant-text and tool event
  with an `at`. This drives the tool dot exactly, and it back-fills the
  sparkline at event resolution for the portion of the window the app has
  events for.

```swift
nonisolated struct Sample: Sendable, Hashable {
    let at: Date
    let charsPerSec: Double
    let toolsPerMin: Double
    let blockedFor: TimeInterval?
}
```

`SampleRing` is a value type wrapping `[Sample]`, capped at 360 (≈30 min at 5 s),
trimmed with a single `removeFirst(count - 360)` — never `removeFirst()` in a
loop, which would make appending O(n²).

**The sparkline is plotted against real timestamps, not sample index**, and is
not smoothed. A network stall shows as a flat run rather than being interpolated
over. At a 5 s cadence a 90-second window is about 18 points — the mark is
styled for what it actually is rather than for the 360-point curve the prototype
drew against a fabricated 250 ms model.

The ring **belongs to the `Channel`** and is discarded with it. There is no
fleet-wide sample store, because there is no fleet-wide readout.

### 5.5 The sparkline window

Prime and Telemetry both used pull-down-past-the-top for this; §4.7 gave that
gesture to hard-refresh and history-paging instead. The window gets its own
control on the mark itself:

**Drag horizontally on the sparkline.** Left narrows, right widens, 1:1 against
a log scale from **90 s to 30 min** (the ring's full retention). Rubber-banded
at both ends. A chip above it reads the real span (`90 s`, `4.5 min`, `30 min`).
Detents at 90 s / 5 min / 30 min with a `.selection` haptic. Released, it stays
where it was put, per channel, for the session.

The mark's own hit area is 342×44 pt (the visual is 30), so the drag does not
compete with the thread's scroll below it.

### 5.6 The context gauge — three states, one of them not zero

`SERVER-PLAN.md` §9.7 resolved the spike: `contextUsed` has a real source, the
`statusLine` payload's `context_window.used_percentage`, computed by the CLI
itself. **The gauge ships.** But it has three states and only one of them is a
number:

| state | condition | UI |
|---|---|---|
| **known** | `contextUsed != nil` | `32 %` in the cell; the bar fills to that on `meter`; both go `sig` above 85 % |
| **not yet** | `contextAvailable == true`, `contextUsed == nil` — the session has not taken its first turn, so the CLI reports `null` | the cell reads `—` with no unit; the bar renders as an **empty `ink5` track with no fill**; both animate into their real values on `meter` when the first sample lands |
| **unavailable** | `contextAvailable == false` — hotline's statusLine wrapper is not installed for that session | **the cell is not rendered at all** (the strip lays out with three cells, evenly, and looks finished) and **the bar is absent, not empty**. Settings' diagnostics section says once, in words: *"context use: not reported for this session."* |

The distinction matters and is why §11 asks for one boolean: an empty track that
is going to fill in thirty seconds and an empty track that will never fill look
identical and mean opposite things. Rendering the permanent case as `—` forever
would be the fabricated-readout failure this project has already refused once;
rendering the transient case as `0 %` would be a lie in the other direction.

**Because the percentage is what the CLI computes, percent is what is shown.**
Telemetry's prototype displayed a token count (`141k`); we deliberately do not,
because the wire carries a fraction and inventing a token figure from it would
require the window size, which is not on our wire.

### 5.7 Cut: the live patch card

Telemetry's most striking in-channel element streams a diff line by line at
exactly the agent's output rate — *"line cadence = tokens/s ÷ tokens per line.
There is no second clock anywhere in this."* The mechanism is excellent and the
data does not exist.

`SERVER-PLAN.md` §2 deliberately keeps file content off the wire: the `events`
table stores the tool name plus a ≈200-character one-line summary, and the
authoritative record stays in the transcript on disk. §9.7 did not change that.
Streaming invented lines at a real rate would still be an animation encoding
nothing, which §9.1 forbids.

**What ships instead** is the tool row it would have replaced: `Edit
ChannelStore.swift · +41 −18` with its duration bar. The `+41 −18` is real,
because it is in the summary the server already writes.

**What would make it shippable**, if he wants it: one nullable `diff` column on
`events`, populated for `Edit`/`Write` from the tool input the hook already
receives, capped at ~40 lines. Then the card streams the real hunk at the real
rate and every number in it is true. That is §11's fourth ask and it is the only
one that is a design decision rather than a formality.

---

## 6. The map

One layer, merging Prime's route timeline with Telemetry's recorder strip. It is
pushed into from a channel, not a tab — the contradiction noted in `DESIGN.md`
(he described a per-agent map in detail, then selected only `Chat` when asked
which tabs he wanted) is resolved the way it was flagged to him.

### 6.1 Getting there

Pull the phase chip under the agent name downward. `p = chipStart + dy/height ·
1.35`, rubber-banded past 1. The reveal starts as soon as it is peeking
(`p > 0.04`) rather than at the commit, so the panel is never a blank rectangle
sliding down. Commit threshold 0.42 on the projected end. The layer underneath
is pushed back and softened, not merely dimmed — `brightness(1 − 0.5·e)`,
`blur(round(e·5))`, `offsetY = −e·10`, `scale = 1 − 0.03·e` — because it is
behind something now and should read that way. Push it back up by the grabber,
or tap it.

The panel's contents stage themselves as they arrive (`mapRev` on `enter` with a
90 ms delay): the spine draws down `scaleY = clamp(v·1.15, 0, 1)` and the phases
follow it, `sm(clamp((rev − i·0.10)/0.5, 0, 1))`. The reveal is torn down 440 ms
*after* the panel has left, not on release — resetting on release empties the
map while he is still watching it go.

### 6.2 The timeline

Phases from `POST /agents/history`'s phase records: `title` (frozen at open,
never updated — a title that shifts under a finger mid-scroll is worse than a
duller one that holds still), `outcome`, `started_at`, `ended_at`. Tool calls
nest under their phase via `events.phase_id`.

- The focus band sits at **170 pt** from the top of the map view. The phase
  nearest it opens its tool calls. `on = clamp(1 − |top − 170|/210, 0, 1)`.
- The content has a 170 pt lead-in and a 380 pt run-out. Without them the
  timeline can never bring its own ends into the band — and the last phase is
  exactly where a blocked agent lives.
- Tool rows stagger open: `q = clamp((on − k·0.055)/0.6, 0, 1)`, `offsetX =
  (1−q)·(−12)`.
- The tools container height is `round(on · n·27 + 2)` and is **written only
  when the rounded value changes**. Height is the one non-compositor property in
  this screen — there is no transform equivalent for a list closing a gap — so
  it is not written per frame.
- Release snaps to the phase nearest the projected end, on `snap`.
- A `map-foot` names the empty space below the last phase (*"Route continues
  when you answer"* / *"End of route"*). Empty screen that is actually the
  future must be named or it reads as a rendering bug.

### 6.3 The recorder strip, and its link to the timeline

A 342×104 strip above the timeline, holding:

- **phase segments** — a hairline at each boundary, a two-digit index label,
- **the throughput waveform** — see the honesty note below,
- **the blocked span** — a `sig12` rectangle with a `sig` baseline over any
  interval where the agent was waiting on him (`conversations.waiting_since` →
  answered). Exact,
- **tool ticks** at the bottom, one per `tool_use`, coloured by kind,
- **the playhead** — a `sig` vertical line with a knob.

**Tool tick colours.** `Read`/`Grep`/`Glob` → ink 30 %, `Edit`/`Write` → ink
58 %, `Bash` → ink 92 %, `Task`/`Agent` and block events → `sig`, **anything
else → ink 44 %, and the key says `other`.** A four-way classification of an
open-ended tool namespace would silently mislabel every MCP tool; a fifth bucket
that admits it does not know is the honest version.

**The waveform's source, and its limit.** There is no throughput series on the
wire. The app builds one from the assistant-text events it holds for that agent:
characters between consecutive assistant events, divided by the wall time
between their `at` values. That is real, and it is coarse, and it **stops where
the fetched history stops.** The strip therefore renders a run-in at its left
edge labelled *"older history not loaded"* rather than drawing a line back to
zero. Paging more history in extends the waveform leftward. Nothing is
synthesised to fill it.

**A compaction is marked on the strip.** `SERVER-PLAN.md` §9.7 gives a real
structural marker in the transcript (`compact_boundary` with `preTokens`,
`postTokens`, `durationMs`), so a compaction becomes a labelled vertical rule on
the waveform — the one place where the context history *does* exist, as two
points either side of a boundary.

**`CONTEXT at cursor` does not ship as a readout.** `Vitals` is a live snapshot
and there is no context *series* behind it — the statusLine payload is not
recorded per turn. The recorder's readout row is `AT`, `OUTPUT`, `PHASE n of m`
— three cells, all sourced.

**Scrub ↔ timeline is one value seen twice.** The failure mode here is a
feedback loop: the strip drives the list, the list drives the strip, and they
oscillate. The prototype breaks it with a "quiet" write. This spec makes it
structurally impossible instead:

```swift
enum Driver { case strip, timeline, neither }
private var cursor: TimeInterval
private var driver: Driver
```

The strip's gesture sets `driver = .strip` and writes `cursor`; the timeline's
scroll observer only writes `cursor` when `driver != .strip`, and vice versa.
`driver` returns to `.neither` when a gesture ends. One enum, invalid
combinations unspellable, no flag to forget to clear.

Scrub gesture: 1:1 with the finger across `SW = 342` pt mapping the full
session; rubber-banded past the ends; momentum on release; snaps to a phase
boundary if the projected end lands within 4.5 % of one; `.selection` haptic at
each boundary crossed and at the snap.

### 6.4 Purge from the map

Scrubbing to a point and purging everything before it is the natural use of a
cursor, and `POST /agents/purge` takes `before_seq`. The map's overflow control
offers *"Delete everything before here"*, which resolves the cursor to the
nearest event's `seq` and hands it to §8's flow — same dry-run sheet, same
hold-to-fill, same slam card.

---

## 7. Controls

`Agent.controls: [Capability]`, plus `globalControls` from `/health` for `new`.

```swift
nonisolated struct Capability: Codable, Sendable, Hashable, Identifiable {
    let id: String        // "stop" | "kill" | "retask" | "resume" | "new" | "compact"
    let label: String
    let enabled: Bool
    let reason: String?
}
```

**The rules, which exist because reinstalling costs him a week of provisioning:**

1. The app hardcodes **only** the endpoint and body shape for each `id` it knows
   how to dispatch. That is an ordinary client/server contract.
2. It **never** hardcodes which capabilities exist, their order, their `label`,
   their `enabled`, or their `reason`. The control surface is a `ForEach` over
   the server's array.
3. A capability whose `id` this build cannot dispatch renders **disabled**, with
   the server's label and the reason *"this build can't do that yet."* It is not
   hidden. Hiding it makes a server that has moved ahead of the app invisible;
   showing it tells him he needs a new build, which is exactly the information
   that is expensive to discover any other way.
4. **`enabled == false` renders visible, dimmed, and tapping it surfaces the
   `reason` as a toast.** A disabled control that does nothing when tapped is
   indistinguishable from a broken one. The reasons are already written for this
   — *"running headless — its turn can't be interrupted, only killed"* is a
   sentence he should be able to read on the phone.
5. **Server-side enforcement is independent.** `/agents/stop` returns 409 on its
   own even against a stale client. A 409 is rendered as its message, not as a
   generic failure.

### 7.1 Where controls appear

| surface | what | why |
|---|---|---|
| **row swipe left** | the first two of `stop`, `kill` present in the array | reachable without opening anything |
| **row swipe right** | `retask` if present, else `resume` | the label follows the agent's actual state — a dead agent offering "Retask" is the sort of stale label nobody reports and everybody feels |
| **channel control sheet** | *every* capability, with label, state and reason | the list is server-declared and open-ended, so there must be a surface that renders N of them |
| **pull up past the bottom of the list** | `new` | from `globalControls`; if disabled the sheet still opens and shows the reason instead of the field. The gesture is never a dead end |

The channel's state line (`Waiting on you` / `Running` / `Not running`) is the
control sheet's affordance: tap it. It is already the place he looks to find out
what the agent is doing.

### 7.2 Kill, stop, and the asymmetry

`SERVER-PLAN.md` §4 is explicit that the copy must not imply two strengths of
the same thing:

- **Stop** interrupts the current turn. The session survives and can take new
  work. **No confirmation.** It is reversible in the only sense that matters —
  the agent is still there.
- **Kill** ends the session. It only comes back through Resume, and only if it
  left a handoff or a transcript. **Confirmation: the 1 500 ms hold-to-fill of
  §9.5**, and then the slam card. It is also the only control a fling can never
  commit (§4.7).

The control sheet renders those two sentences under the two controls. Not as
help text — as the labels' subtitles, always visible.

### 7.3 Retask

`POST /agents/retask {agent, text, stop_first}`. One request, composed
server-side, because two calls from a phone means a dropped network can leave an
agent cancelled with nothing queued to replace it.

UI: a text field, and a `Stop the current turn first` toggle. **The toggle is
disabled and explained when that agent's `stop` is not enabled**, because the
server refuses `stop_first` rather than silently downgrading it, and the app
must not offer what will be refused. Response `{delivered, queued}` is rendered
as it is: *"queued — it will start after the current turn"* is a different
outcome from *"started"* and reads differently.

### 7.4 Compact — and it reports what it actually did

One button. `POST /agents/compact {agent, then?}` composes interrupt → `/compact`
over the pty → wait on the real completion marker → continue, all server-side,
for the same reason retask does.

```swift
nonisolated struct CompactResult: Codable, Sendable {
    let interrupted: Bool
    let compacted: Bool
    let resumed: Bool
    let preTokens: Int?
    let postTokens: Int?
    let durationMs: Int?
}
```

`SERVER-PLAN.md` §9.7 established that these are real numbers read out of the
transcript's `compact_boundary` record, not a timer and not an estimate. So the
button reports them:

- **On success**, a `state` moment is appended to the thread — not a toast,
  because this is a fact about the session and belongs in the record:
  **`Compacted — 48k → 4.1k in 71s`**. `preTokens`/`postTokens` are formatted to
  one decimal below 10 k, integer above.
- **The context bar visibly falls.** The next roster tick carries the new
  `contextUsed` and the bar animates from the old value to the new one on
  `meter`. **The app does not compute the new value from `postTokens`** — it has
  no window size and would be guessing; it waits ~5 s for the real sample and
  lets the fall be a real measurement. That drop is the payoff of the button and
  is the clearest possible example of an animated quantity encoding a real
  number.
- **`resumed: false` is a valid, honest outcome** — it means the server declined
  to fire a continuation. It renders as *"Compacted — not resumed"* with a
  `Continue` button that issues a retask. It is **not** an error and **not** a
  success.
- **`compacted: false`** renders whatever the server said went wrong, verbatim.

`compact` needs the same pty as `stop`, so a headless session shows it
**disabled with its reason, never hidden** (`SERVER-PLAN.md` §9.6). If the
server does not declare the capability at all, the app renders nothing and needs
no change — which is the correct behaviour and the reason the app must never be
built around the assumption that compact exists.

---

## 8. Deletion and retirement

Per `SERVER-PLAN.md` §3. Two operations, not five, and they look nothing alike.

### 8.1 Retire — reversible, visibility only

`POST /agents/retire {agent, retired}`. A flag orthogonal to live/busy/dead; an
agent can be live and retired at once.

- Surface: a plain toggle in the control sheet, labelled `Show in fleet`.
- **No confirmation.** Nothing is destroyed.
- A retired agent leaves the main list and appears in a collapsed `Retired (4)`
  section at the bottom. It keeps its live dot in there, because it may still be
  running.
- Nothing about it is styled as destructive. No `sig`, no warning colour.

### 8.2 Purge — irreversible, and it looks it

`POST /agents/purge {agent, scope, conversation_id?, before_seq?, dry_run?}`.

The flow, in order:

1. Control sheet → `Delete history…`. Scope picker: **`history`** (delete events
   and phases, keep the agent) or **`everything`** (also drop the agent record).
   Optional narrowing: a single conversation, or `before_seq` handed in from the
   map cursor (§6.4).
2. Issue the call with `dry_run: true`.
3. **The count sheet is built from the real counts the server returns** —
   `conversations`, `events`, `phases`, `oldest_at`:

   > **hotline-80**
   > 340 events, 6 conversations, 4 phases
   > oldest 12 Aug
   > This deletes them on archserver. It cannot be undone.

   Never a generic warning. The number is the consent.
4. **Hold to confirm** — the 1 500 ms linear fill of §9.5, the same component
   the kill control uses, cancellable the whole way.
5. If the sheet has been open more than 10 seconds, **re-run the dry run before
   the destructive call.** The counts are what he consented to; consenting to
   stale counts is not consent.
6. The slam card fires with the word `DELETED` and the counts as its sub-line
   (§9.5).
7. On success: bump the local generation, `removeItem(at:)` the agent's cache
   directory, and — if the scope was `everything`— drop the `Channel` and pop
   back to the fleet list. The app's local copy disappears only as a side effect
   of the real deletion succeeding.

**Per-event deletion is explicitly not planned** and has no UI.

### 8.3 "Free up space" — separate, and clearly not deletion

In Settings, nowhere near the purge control, in ordinary ink rather than `sig`:

> **Free up space** — 18.4 MB
> Clears the copy on this phone. Nothing on archserver is deleted; the app
> re-downloads what it needs.

The label says what it does, in its own words, per `SERVER-PLAN.md` §3. It is
one `removeItem(at: hotlineDir)` on the `Cache` actor plus a `Channel` reset. It
has no hold-to-fill and no slam card, because it is not destruction.

### 8.4 `historyGeneration`

Carried on every roster row. In `Fleet.apply(roster:)`, **before anything else
touches a channel**: if a row's `historyGeneration` differs from the cached one,
drop that agent's entire local cache and mark its channel cold. A purge from
anywhere — another client, the CLI, a script — therefore reaches the phone
within one roster wake, with no explicit invalidation protocol.

This also replaces the old `gap` flag. With a persistent server store and one
global `seq`, a hole in an agent's stream is either normal (other agents'
events) or the result of a purge, and the purge case is exactly what the
generation counter reports. **Client-side gap detection is removed.** The
"— some of this was missed —" rule in the thread is kept for the one case it
still describes: a history refetch that returns fewer events than the cache held.

---

## 9. The slam card

Rebuilt from `docs/MOTION-SLAM-CARD.md`, which is extracted from round-1's
`editorial.html`. Its verdict: the animation is the best of the four
("basically cinematic"), the typography and UI choices are atrocious.
**Motion only. Nothing about Editorial's appearance is inherited.**

One shared card, reached from two unrelated pre-rolls that differ in exactly
three ways: the word's colour, the haptic pattern, and what happens after it
resolves.

### 9.1 What it is not

- **There is no shared-element morph.** The card is a fixed, position-agnostic
  full-bleed overlay that always wipes from the bottom edge regardless of where
  the control that triggered it sat. `matchedGeometryEffect` is not used, here
  or anywhere else in this app.
- **It is not spring-driven.** Every curve in it is a cubic-bézier authored
  against the others to the millisecond. Re-expressing them as springs would
  destroy the two things that make it work: the 560 ms overtake and the 320 ms
  held beat.
- **It is not scrubbable and not reversible.** See 9.2.

### 9.2 How it coexists with Kinetic Prime's scene system

This is the integration question and it has one answer.

**The slam card sits *above* Kinetic's scene system as an overlay with its own
lifecycle. It is not folded into it.**

Kinetic's `nav`, `map`, `sheet`, `scrub` and `window` are progress values: they
are scrubbable, reversible, drag-owned, and interruptible at any instant. The
slam card is the opposite by design — its source is explicit that *"a hard
re-entrancy lock is taken at trigger and released only after the whole sequence
completes. No abort, no undo, no back-gesture. Once tapped it is atomic."*
Folding an atomic sequence into a reversible progress value gives you one of two
bad outcomes: the card becomes scrubbable and stops being a commitment, or `nav`
grows a mode in which it refuses to move, which is a lie about what a progress
value is. Keeping them separate keeps both honest.

**The lock.**

```swift
// on Shell, as @State. It is a property of the presentation, not of the data.
@State private var atomic: AtomicRun?          // nil == nothing is committed

struct AtomicRun: Identifiable {
    let id = UUID()
    let flow: SlamFlow            // .answer | .kill | .purge
    let card: SlamCard.Content
}
```

While `atomic != nil`:

| behaviour | rule |
|---|---|
| gestures | every recognizer on Fleet / Channel / Map returns immediately from `.onChanged`; no progress value is written by anything |
| controls | every control is `.disabled(true)`; the back chevron does nothing |
| the blocked-arrival choreography | **queued**, not dropped. `Fleet` records that a beat sequence is owed and runs it on release |
| the streaming feed | **keeps running** — see below |
| the slam layer | takes `.accessibilityFocus` and posts an announcement |

**The feed seam, which is the part that bites.** Events arrive during the card's
~2.1 s, and the answer flow's exit *rebuilds the thread*. If the feed appended
during the card, the thread would mutate behind it and the self-cut would
re-stagger a thread that had changed twice. So:

- `Shell` calls `channel.beginAtomicPresentation()` at trigger and
  `channel.endAtomicPresentation()` in a `defer` at the end of the sequencer
  task. Two calls, symmetric, impossible to leave half-done.
- Between them, `Channel.apply` **still advances `cursor` and still writes to
  the `Cache`** — nothing is lost, no request stalls, no long-poll is left
  unanswered — but the moments are parked in `holdback` instead of `moments`.
- On release, `holdback` is flushed into `moments` in **one** write, so the
  self-cut re-staggers the final state exactly once.

That is the whole interaction between the atomic overlay and the streaming feed,
and it is the reason `holdback` exists on `Channel` in §2.2.

**One consequence worth stating so nobody "fixes" it:** the agent's real reply
to an answer usually arrives during the hold, so the exit shows it. If it has
not arrived yet, the exit shows the question gone and his answer in place, and
the reply lands later with the ordinary fresh-message animation. **The card
never fabricates the agent's reply to fill the beat.** The prototype does
(canned text at +1700 ms) because it had no server.

### 9.3 The sequencer

`PhaseAnimator` is the obvious SwiftUI tool and is the wrong one: it does not
express a real dwell independent of its transitions, and it wants one timeline
where this needs two. The card is driven by **one main-actor `Task` that awaits
`Task.sleep` between beats and drives three independent values with
`withAnimation`** — a 1:1 map onto the beat sheet, with the held beat as a
literal sleep containing nothing.

```swift
@MainActor func run(_ card: SlamCard.Content, flow: SlamFlow) async {
    defer { channel?.endAtomicPresentation(); atomic = nil }
    …
}
```

Three animated values, each its own track. **The mask timeline and the content
timeline are two independently authored tracks, not one derived from the
other** — the source is explicit about that and it is what lets the word keep
settling 330 ms after the wipe has finished.

| value | drives |
|---|---|
| `reveal: Double` 0→1→(exit) | the mask (§9.4) |
| `wordIn: Double` 0→1 | the word's opacity, `offsetY` 16→0, tracking +0.04 em → −0.055 em |
| `subIn: Double` 0→1 | the sub-line's opacity and `offsetY` 11→0 |

**Beat sheet — Flow A (answering), t = 0 at commit.** In this app the commit is
the drag-right release on the answer card (§10), not a tap, so `slamGo` starts
from an option that is already filled.

| t (ms) | duration | what |
|---|---|---|
| 0 | — | lock taken. Chosen option marked, siblings marked dropped. Core Haptics `[10, 40, 18]`. The optimistic `pending` bubble is appended (invisible, behind the card) |
| 0 | 620 | chosen option: `scale(1) → scale(1.42)`, `offsetY 0 → −6`, **opacity never drops**. `.timingCurve(0.16, 1, 0.3, 1)` |
| 0 | 240 | siblings: `offsetY → +22`, `opacity → 0`, `blur → 7`. `.timingCurve(0.23, 1, 0.32, 1)`. **They finish 380 ms before the winner does**, so from 240–620 ms the winning option is alone on screen, still growing into the empty space |
| **560** | 460 | **the card fires — 60 ms before the option's zoom finishes**, so the rising wipe overtakes and buries its tail. `reveal` 0→1 on `.timingCurve(0.16, 1, 0.3, 1, duration: 0.46)` |
| 650 | 700 | `wordIn` 0→1, same curve. Runs to 1350 — **330 ms past the wipe's own completion**, so the word keeps settling while the card is already static |
| 890 | 500 | `subIn` 0→1 on `.timingCurve(0.23, 1, 0.32, 1)`. Runs to 1390 |
| **1390** | **320, dead** | **the held beat. Nothing moves.** `try? await Task.sleep(for: .milliseconds(320))` with no animation scheduled inside it |
| 1710 | 400 | `reveal` exits (§9.4) |
| 2110 | — | card removed. `holdback` flushed; the question card removed from the thread; `pending` reconciled |
| 2110 | 420 | the self-cut (§9.7) |

**The kicker label has no animation at all** — it appears fully formed the
instant it is unmasked. Do not add one.

**The 320 ms dwell is the beat Bogdan praised.** It is the load-bearing pause
that forces the confirmation to be read rather than flash past. It must survive
as a real dwell. Two ways it gets silently optimised away and both are
forbidden: collapsing it into the exit's timing curve, and expressing the
sequence as a single `PhaseAnimator` whose dwell is "however long the previous
transition took". If a reviewer cannot point at a `Task.sleep(for:
.milliseconds(320))` with nothing scheduled in it, the port is wrong.

`Task.sleep` drift at these magnitudes is tens of milliseconds at worst and the
beats are perceptual, not frame-locked. That is acceptable and is why a sequencer
task is preferred to a hand-rolled display-link timeline.

### 9.4 The mask

No stock transition does this. `.transition(.move)` and `.push` translate the
whole view — the content moves — which is the wrong look. Here the content
stays still and the *visible window* grows.

```swift
nonisolated struct InsetReveal: Shape {
    var topInset: Double        // fraction of height, from the top
    var bottomInset: Double     // fraction of height, from the bottom
    var animatableData: AnimatablePair<Double, Double> {
        get { .init(topInset, bottomInset) }
        set { topInset = newValue.first; bottomInset = newValue.second }
    }
    func path(in r: CGRect) -> Path {
        let y = r.minY + r.height * topInset
        let h = max(0, r.height * (1 - topInset - bottomInset))
        return Path(CGRect(x: r.minX, y: y, width: r.width, height: h))
    }
}
```

Applied as `.mask { InsetReveal(...) }` over the full viewport — **not scoped to
the content block**.

- **in:** `topInset` 1 → 0 over 460 ms. The band's top edge travels from the
  bottom of the screen to the top.
- **out:** `bottomInset` 0 → 1 over 400 ms. The band's bottom edge travels from
  the bottom of the screen to the top.

**Both boundaries travel upward.** It is a rising curtain that keeps rising
rather than reversing itself, and getting this backwards is the single easiest
way to lose the effect while the code still "works".

### 9.5 The two pre-rolls

**Flow A — answering.** Trigger is the answer card's commit. Prime's card is
dragged right; releasing past `0.62 × width` (or with `vx > 900` past 60 pt)
commits, the `whip` spring fills it to full, and **that release is `t = 0`
above**. Word `SENT` in `ink`, sub-line = the chosen option's own label, kicker =
the agent name. Haptic `[10, 40, 18]`.

Prime's inline FLIP — the chosen option flying into the stream as his reply at
+210 ms — **is dropped on this path**. The card covers the screen at 560 ms and
would bury its tail, and the source's own model puts the thread rebuild at
2110 ms behind the card. So the reply appears during the covered period and the
self-cut reveals it. The FLIP survives only in fling-to-send (§4.7), where there
is no card.

**Flow B — killing.** Trigger is `Kill` in the control sheet, with the hint
*"Hold. Killing drops unsaved state."*

*The hold-to-fill*, and it is the app's one confirmation component — kill and
purge both use it:

- on press: `.impact(weight: .light)`, and a fill sweeps left→right over
  **1 500 ms, `.linear`**. Linear on purpose: the bar is a clock, and easing a
  clock makes it lie about how much time is left.
- the fill carries a **duplicate of the button label in the inverse colour**,
  masked to `fill × width`. Two stacked `Text` views in the same position, the
  top one masked — so the label inverts under the sweeping boundary rather than
  the boundary sliding over dead space.
- **cancel** on release before 1 500 ms: the fill retracts from wherever it
  reached over **220 ms `.easeOut`** — a fast asymmetric snap-back against the
  slow linear fill. Fully reversible at any point; **nothing is sent and no
  state changes until the timer completes.** SwiftUI animations are natively
  interruptible, so the asymmetric cancel falls out for free.
- `.selection` haptic at 50 %.

*After the hold completes*, `t = 0`:

| t (ms) | what |
|---|---|
| 0 | the control sheet slides down (440 ms `.timingCurve(0.32, 0.72, 0, 1)`), its scrim fades (320 ms `ease-out`). Core Haptics `[18, 60, 18, 60, 26]` — five stages, heavier than the answer's single pattern. The agent's state is set dead locally, optimistically |
| 260 | **the same card**, identical timings to Flow A, word `KILLED` in `sig` |
| after | **no navigation.** You stay where you are. The channel header's state line swaps instantly with no animation; the list row behind updates in place — its dot goes to the hollow dead ring and its subtitle blur-crossfades to the `deadReason` |

The source has the row status "roll to DEAD, 250 ms per character column,
staggered 26 ms". **That is dropped**, because it is a character-flap component
of Editorial's UI and Prime's row has no flap. Importing it would import
Editorial's typography through the back door, which is the one thing this port
is not allowed to do. The blur-crossfade already in §4.6 does the same job in
this shell's own language.

**Flow C — purge** reuses Flow B exactly: same hold-to-fill, same haptic
pattern, word `DELETED` in `sig`, sub-line = the dry-run counts. Reusing the
*same* card for deletion as for a normal decision says something on purpose: in
this app's vocabulary, killed is just another decision — formally identical to
approving, only red.

### 9.6 The animated tracking, and how it is verified rather than assumed

`.tracking()` does not reliably interpolate under implicit animation across OS
versions and can jump-cut between two typeset states. This is the highest-risk
line in the port because it fails *silently* — the word still appears, it just
stops being the decision locking down typographically.

**Implementation.** Not a bare `.tracking()` on an animated value. An
`Animatable` modifier that owns tracking as its `animatableData` and applies it
inside `body`, so SwiftUI interpolates the number and re-typesets each frame —
the same pattern as §4.3's `Stage`:

```swift
nonisolated struct Tracked: ViewModifier, Animatable {
    var value: Double                                   // points
    var animatableData: Double { get { value } set { value = newValue } }
    @MainActor func body(content: Content) -> some View { content.tracking(value) }
}
```

**Verification, on device, before this is called done:**

1. Set the card's word to a 9-character string (`COMPACTED`).
2. Screen-record at 60 fps on the phone and step the recording frame by frame
   across t = 650…1350 ms.
3. Count frames on which the total rendered width of the word changes.
   **Pass: ≥ 8 distinct widths. Fail: ≤ 2**, which means it is jump-cutting
   between two typeset states.

**Fallback if it fails**, decided in advance so nobody improvises: lay the word
out as individual `Text` glyphs in an `HStack(spacing: 0)` with `.offset(x:)`
accumulated from the animated tracking value. That interpolates positions rather
than re-typesetting and cannot jump-cut. Cost: kerning pairs are lost, which is
acceptable for one uppercase word and unacceptable for body text — which is why
this fallback is scoped to the slam word only.

The same verification applies to the hero title's animated tracking (§4.4),
which has the identical risk and the identical fallback.

### 9.7 The screen cut

After the card leaves, the destination replays its own arrival:

- outgoing: 260 ms `ease-out` — `opacity → 0`, `scale(0.965)`, `blur 0 → 5`
- incoming: 420 ms `.timingCurve(0.16, 1, 0.3, 1)` — `opacity → 1`,
  `offsetY 20 → 0`, `scale(0.985) → 1`
- messages re-enter staggered **52 ms per index**

**The quirk is kept deliberately.** When the answer came from the inline
in-thread question, the destination is the screen he is already looking at, and
it *still* replays its arrival — every message re-staggers from scratch. A hard
self-cut, not a no-op. It reads as *"this is now a new scene"* even though
nothing navigated, and that is exactly true: the question is gone, his answer is
in, and the agent has moved. In SwiftUI this is a `cut: Double` 0→1 on the
channel layer reusing §4.3's staging windows, bumped by a `sceneEpoch: Int`.

### 9.8 Reduced motion

Shortened and de-directionalised, **not removed** — the source's own note says
"gentler, not zero". Same sequence, same order, every directional transform
stripped, durations compressed ~2.5–3×, all stagger removed.

| element | normal | reduced |
|---|---|---|
| option go / drop | 620 / 240 ms with transforms | plain opacity crossfade, 200 / 160 ms |
| card pre-delay | 560 ms | 200 ms |
| mask wipe, word press, sub fade | 460 / 700 / 500 ms with offsets and tracking | a flat 220 ms fade, zero delay, no offset, no tracking animation |
| **the held beat** | **320 ms** | **150 ms — shortened, never removed** |
| exit + cleanup | 400 ms | 180 ms |
| kill hold-to-fill | 1 500 ms | 600 ms |
| screen cut | 260 / 420 ms | 200 / 160 ms, stagger 0 |

The held beat surviving reduced motion is the point of the whole card. It is a
reading pause, not an animation, and someone who has asked for less motion has
not asked for less time to read.

---

## 10. Merge decisions

The three sources agree almost everywhere. These are the places they genuinely
disagreed, and how each is resolved.

| element | source A | source B | resolution |
|---|---|---|---|
| list→channel transition | Prime: orchestrated disassembly on one progress value | Telemetry: horizontal push | **Prime.** Not close |
| **telemetry on list rows** | Telemetry: rail, sparkline, tool-flash dot, host chip | Prime: none | **Prime — none.** Bogdan's explicit scoping, 2026-08-26 (§5.0) |
| **the fleet aggregate and meter** | Telemetry: `FLEET OUTPUT` + a 342×30 meter in the list header | Prime: none | **Cut.** It is a list-screen readout and the list carries no telemetry |
| **the sparkline** | Telemetry: on rows and in the list header | — | **Moved into the channel strip** (§5.3). Its geometry survives; its screen does not |
| the status dot | Prime: state pulses (3.6 s / 1.15 s / 1.7 s) | Telemetry: one flash per tool call | **Both, by surface.** Prime's categorical pulse on the list, Telemetry's exact per-call flash in the channel (§5.1) |
| pull down past the top | Prime: rewind through three past snapshots | Telemetry: widen the sparkline window | **Neither.** The list uses it for hard refresh, the thread for older history; the window moved onto the mark itself (§4.7, §5.5) |
| blocked news reaching him | Prime: coach toast | Telemetry: signal banner | **Both, by context** — toast on the fleet layer, banner elsewhere (§4.6) |
| the map | Prime: route timeline with a focus band | Telemetry: recorder strip + scrubbing | **Both, one layer** (§6) |
| composer send | Prime: fling with ghost + FLIP | Telemetry: tap | **Prime's fling**, with tap doing the same thing |
| answer commit | Prime: drag right, `whip`, FLIP into the stream | Slam card: tap, no morph, full-bleed card | **Prime's drag-right gesture as the trigger; the slam card as everything after.** Prime's FLIP is dropped on this path only (§9.5) |
| kill confirmation | Prime: none (fling excluded, tap only) | Slam card: 1 500 ms hold-to-fill | **Slam card's**, and it becomes the app's only confirmation component (§9.5) |
| the live patch card | — | Telemetry: streaming diff at the meter's rate | **Cut** — no source (§5.7). Shippable with one server field |
| row status roll on kill | — | Slam card: per-character flap | **Dropped** — it is Editorial's UI, not its motion (§9.5) |

---

## 11. Asks of the server plan

Small, and each one buys a specific readout that otherwise cannot ship honestly.
None of them blocks the app; each turns a "renders nothing" into a "renders the
truth".

| ask | why | cost |
|---|---|---|
| `declared_at` on the roster row | the strip's `ELAPSED` cell. It is already a column in `agents` | one field |
| `contextAvailable: Bool` on the roster row | distinguishes "no first turn yet" from "no statusLine wrapper installed". Without it the two render identically and mean opposite things (§5.6) | one bool |
| `duration_ms` on an event row | the tool-row and timeline duration bars. It is already in the `PostToolUse` hook payload and is discarded today | one nullable column, one field |
| `client_token` echoed on `/say`, `/reply`, `/retask`, carried on the resulting event | makes bug 3's reconciliation exact rather than FIFO-sound, and makes a retry-after-timeout detectable as a duplicate rather than delivering twice | one nullable column, one field |
| **optional:** a `diff` column on `events`, ≈40 lines, for `Edit`/`Write` | the only thing that would let Telemetry's live patch card ship honestly (§5.7). This one is a design decision, not a formality — it puts file content on the wire, which §2 currently avoids on purpose | one column, one policy change |

The FIFO reconciliation in §1.1 is correct without `client_token` and ships
first; the token upgrades it from "sound because this phone is the only writer"
to "sound by construction".

---

## 12. Open questions for Bogdan

**ALL ANSWERED 2026-08-26. Nothing in this document is open.** The questions are
kept below for their reasoning; each now carries its decision.

| question | decision |
|---|---|
| 12.1 deployment target | **iOS 18.** His phone is on 18.7.8. `Package.swift` is `.iOS(.v18)`. **Two claims in the original question were wrong and are corrected below.** |

> **Correction, verified against the SDK during step 0–3.**
>
> - **`Observations` is iOS 26+, not 18** (`@available(macOS 26.0, iOS 26.0, ...)`).
>   It cannot be used on this target at all. Nothing is lost — `.task` plus
>   `@Observable`'s per-property tracking is what the app uses — but do not plan a
>   store↔view seam around it.
> - **`ScrollPosition` deletes none of the three custom scroll surfaces.** Every
>   reason §4.7 gives for making them custom — one recognizer arbitrating row-drag
>   against scroll, pull-past-bottom-to-brief, per-surface pull-past-top meaning,
>   rows whose order and height animate independently, the scene change reading row
>   positions — is untouched by a programmatic offset read/write. **§4.7 is right;
>   this row's original parenthesis was wrong.** All three surfaces are custom.
>
> Raising the target still stands on its own: there is no second device to support.

> **iOS 26 was offered and declined, 2026-08-26.** He volunteered to upgrade the
> phone if the build needed it. It does not: the toolchain already carries
> `iPhoneOS26.2.sdk` so targeting 26 is possible, but nothing in this document
> depends on a 26-only API. `Observations` was the only one ever cited and the
> app does not use it. Set against that, a major OS upgrade on the only test
> device — mid-build, over a working sideloaded install, with re-pairing risk on
> a setup that already cost us the device limit once — is real risk for no named
> benefit. **Staying on 18.7.8.** Revisit only if a specific 26-only API turns
> out to be required; bumping the target is one line.

### 12.4 The typeface — decided 2026-08-26

**Bundle Geist.** Kinetic Prime, the concept he approved, is set in Geist, and
that is the face he judged. SF differs visibly in width and character, and
Prime's density and type ramp were tuned against Geist.

Ship it with `Theme.family` retained as the one-line fallback to SF, because the
SwiftPM-resource plus runtime-registration path through xtool is untested here
and cannot be verified without the device. **Verify the font actually lands in
the `.ipa` by inspecting the archive**, not by a clean build — a build that
silently drops a resource looks identical to one that carries it.

### 12.5 `done` vs `dead` — decided 2026-08-26

**`done` gets its own dot appearance.** The daemon deliberately separates an
agent that finished and said so from one whose process is gone and never said
anything, and its own comments call that distinction the point. Collapsing them
throws away a true fact at exactly the glance where it matters.

So the dot vocabulary is **five** states, not four: live, busy, blocked, done,
dead. The mapping from the daemon's `idle | working | done | dead` plus its
separate `blocked` boolean stays a single named function, so it is one edit if
the server's vocabulary moves again.

This is the design rule the redesign won on, applied: density of true things per
glance. A clean finish and a crash must not look the same.

| 12.2 auto-open | **The recommended three-condition rule**, exactly as specced: one blocked agent only, cold launch or 5+ min backgrounded, not backed out of that channel in the last 60 s, and it runs the same transition his tap runs. |
| 12.3 server fields | **The four formalities are approved** — `declared_at`, `contextAvailable`, `duration_ms`, `client_token`. **The `diff` column is declined:** the live patch card stays cut and §5.7's tool row ships instead. File content does not go on the wire. |


*(The question about Telemetry's dual-meaning rail is gone rather than answered:
he scoped telemetry out of the list screen, and the rail was a list-row element.
It no longer exists in the design, and the same dual encoding is not
re-introduced anywhere else.)*

### 12.1 Deployment target

`Package.swift` says `.iOS(.v17)`. Everything in this document builds and runs on
17. Four things get materially better at 18+: `ScrollPosition` (would let two of
the three custom scroll surfaces go back to `ScrollView`), `Observations` (a
cleaner store↔view seam than `.task` loops), richer `sensoryFeedback` cases, and
some `symbolEffect` variants.

**Question: what iOS is his phone actually on?** If ≥ 18, recommend raising the
target — there is no second device to support and a lower target buys nothing.
If he would rather stay on 17, nothing here changes; we keep all three custom
scroll surfaces.

### 12.2 The auto-open rule

*"Opening the app can land you on whichever agent needs you most."* Prime's boot
sequence opens a blocked channel by itself. On a real launch, that is a decision
about when the app is allowed to move under him.

**Recommendation:** auto-open only when all three hold —

1. exactly **one** agent is blocked after the launch hard-refresh (two or more
   and it stays on the list with them pinned; picking one would be a guess),
2. the app was launched cold or has been backgrounded more than 5 minutes,
3. he did not back out of that same channel in the last 60 seconds.

And it runs the *same* transition his tap runs — the app performs the gesture
rather than cutting to a screen, which is the difference between it feeling like
it moved and it feeling like it lost his place.

**Question: is that the rule he wants, or should it always land on the list?**

### 12.3 The server fields in §11

Four formalities (`declared_at`, `contextAvailable`, `duration_ms`,
`client_token`) and one real decision (`diff`, which would put ~40 lines of file
content on the wire and is the only thing that makes Telemetry's live patch card
shippable). All on his own daemon.

**Question: add the four? And does he want the patch card enough to put diffs on
the wire?** Without any of them the app renders fewer readouts, correctly and
without complaint.

---

## 13. Implementation order

Each step builds with `xtool dev build --ipa`, installs, and can be judged on
the actual phone. No step depends on a later one. The judging criterion is
stated for each, because "it builds" is not the bar.

**0. Ground.** `Theme.swift` (tokens, type ramp, the spring table), the layer
`ZStack`, the fleet list rendered from a hardcoded in-memory roster with real
rows, dots and hairlines. No network, no telemetry.
*Judge:* hold it up. Does the density and the type read as Prime on a real
screen, at real brightness?

**1. Wire and roster.** `Wire.swift` rewritten, `Link` extended to
`SERVER-PLAN.md` §6's endpoint table, `Fleet` with the launch hard-refresh, the
`roster-events` long poll, and scene-phase re-arm. Reachability banner and the
stale-roster state.
*Judge:* leave it open for ten minutes without touching it. The list must change
on its own. This is bug 1's first half, proven.

**2. The custom list.** Absolute rows, one gesture arbiter with axis lock and
hysteresis, rubber-band, momentum, pull-to-refresh, pull-to-brief, row swipe
revealing capability controls read from the server — **rendered but not
dispatched**, including the disabled ones with their reasons.
*Judge:* fling it, drag a row halfway and let go, scroll to the bottom and past
it. Does it feel like iOS or like a web page?

**3. The scene change.** `nav`, the `Animatable` stage modifier, the full
staging table, the hero flight (with the §9.6 tracking verification), the
interactive pop from the left edge.
*Judge:* drag from the left edge to halfway and back without letting go — does
it track 1:1? Fling it back and immediately tap the row again — does it retarget
without a jump?

**4. Channels.** `Channel`, the `Cache` actor, the hard-refresh-then-stream
seam, older-history paging, the composer with `pending` reconciliation.
*Judge:* the three bugs, by explicit reproduction. (a) Open a channel and say
nothing — messages must arrive. (b) Back out, open a different agent — the
thread must be that agent's, immediately. (c) Send "yes" twice — both must
survive. Then kill the app and reopen a channel: history must be on screen
before a spinner would have appeared.

**5. In-channel telemetry.** `Vitals`, `SampleRing`, the four-cell strip, the
sparkline and its window scrub, the context gauge and its three states, the tool
dot, tool-row duration bars.
*Judge:* open a dead agent. Every readout must be zero and every mark must be
still. Then open a busy one and watch the context bar for a minute — it must
move, and only when a real sample lands.

**6. Controls.** Dispatch, the control sheet, retask, compact and its real
numbers, the honest `resumed: false` path.
*Judge:* point the app at a headless session and confirm `stop` and `compact`
are visible, dimmed, and say why when tapped. Then compact a real session and
watch the context bar fall.

**7. The blocked arrival.** All six beats, roster-driven, plus the signal banner
and the coach-toast branch.
*Judge:* block an agent from the CLI while watching the list, then again while
inside a different channel. Both must land, and the climb must visibly overtake
the parting rows.

**8. The map.** Phases, nested tool calls, the focus band, the recorder strip,
scrub ↔ timeline with the `Driver` enum, the waveform with its honest left edge,
compaction markers.
*Judge:* scrub the full session and confirm the timeline follows without
oscillating, and that the phase snap lands where the throw was going.

**9. The slam card.** `InsetReveal`, the sequencer task, the atomic lock and the
`holdback` seam, Core Haptics, the hold-to-fill, both flows, the self-cut, the
reduced-motion table. Requires steps 4 and 6.
*Judge:* the 320 ms dwell, on device, by eye — does it hold long enough to read?
And the §9.6 tracking test, counted frame by frame. Then answer a blocked agent
while its feed is actively delivering, and confirm the thread does not mutate
behind the card.

**10. Deletion, retirement, settings.** The dry-run count sheet, the shared
hold-to-fill, the `DELETED` card, the retire toggle and the retired section,
"free up space", the diagnostics section that explains an absent context gauge.
*Judge:* run a purge on a scratch agent and confirm the phone's copy is gone and
the fleet list catches up within one roster wake.

**11. Polish.** Reduce Motion sweep against §4.9's principle, the haptic budget
audit, blur quantisation check, Dynamic Type at `.accessibility1`, a VoiceOver
pass over every custom scroll surface, and the Instruments run that decides
whether §3.2's `@concurrent` candidates are real.
*Judge:* turn on Reduce Motion and use the app for five minutes. Nothing should
be missing; everything should be quieter; the held beat should still be there.

---

## 14. What building steps 7–10 found wrong with this document

Recorded here rather than silently worked around, because every one of them is
a place where the plan and the daemon disagree and a later reader would
otherwise re-derive the same surprise.

### 14.1 The map's phases are not on the history page — §6.2 is wrong

§6.2 says *"Phases from `POST /agents/history`'s phase records"*. There are
none. `SERVER-PLAN.md` §6's own response column for that endpoint reads
`{events, oldest_seq, newest_seq, has_more}` — it never promised them either —
and `Service.history` returns exactly that plus `historyGeneration`. The daemon
does keep a `phases` table with `title`, `outcome`, `started_at` and `ended_at`,
and **no endpoint serves it.** Verified against `100.72.2.62:8789` on
2026-08-26 and captured as `app/wiretest/fixtures/live-history.json`.

What it sends instead is strictly more useful: the route inline in the event
stream. A `kind: "phase"` row carries the leg's title and id, a `kind:
"outcome"` row carries the closing line and the same id, and every `tool` and
`compact` row is tagged with the id of the leg that was running — which is the
*nesting* as well as the records. `Store/Route.swift` reconstructs from that,
and still honours `HistoryPage.phases` if a daemon ever starts sending it.

Consequence for the app: `Moment.Kind` grew `phase`, `outcome` and `compact`.
Before this they all decoded as `.summary` and the route was invisible.

### 14.2 There are no options on the wire — §9.5's Flow A cannot ship as written

§9.5's answer pre-roll grows *the chosen option* while *its siblings* drop away,
and the card's sub-line is *"the chosen option's own label"*. Nothing on this
wire offers options. `/api/v1/conversations` carries `asked` as free text and
nothing else, and no part of `server/` has a concept of offered choices.

Rendering Approve/Hold buttons would fabricate a decision the agent never
offered, which §9.1's rule forbids exactly as loudly as a fabricated readout.
What ships: the answer card itself runs `slamGo`, `slamDrop` has nothing to drop
and its 240 ms window is empty rather than faked, and the sub-line is **his own
answer** — the true analogue of what he committed to. Every timing after t = 0
is unchanged, including the 560 ms overtake, because the card fires on a clock
rather than on the pre-roll finishing.

### 14.3 A past blocked span has no source — §6.3's recorder is narrower

§6.3 draws the blocked span from `conversations.waiting_since → answered`. The
daemon's `/conversations` reports `answered` as a **boolean with no timestamp**,
and holds the whole set in memory rather than in the store, so it does not
survive a restart. A *past* blocked interval therefore has no source at all.

The current one does — `blockedSince` on the roster — so the strip draws the
block it can measure and draws no others. Inferring spans from the fact that an
answer exists would be the same class of invention.

### 14.4 The stagger in §6.2 does not resolve past the eighth tool row

`q = clamp((on − k·0.055)/0.6, 0, 1)` reaches 1 only up to `k = 7`. At full
focus the ninth row and beyond sit at ~0.84 — slightly indented and slightly
faded, permanently. It reads as depth rather than as a bug, so the numbers are
kept as written and the property is asserted in `app/wiretest/` so nobody
"fixes" it into a flat list later.

### 14.5 `include_done` / `include_retired` were never asked for

§12.5 gives `done` its own dot and §8.1 gives retired agents their own section,
and `/api/v1/agents` defaults both flags to `false` — so neither state could
ever appear. The roster now requests both. This is a plan omission rather than a
contradiction, but it made two decided features unreachable.
