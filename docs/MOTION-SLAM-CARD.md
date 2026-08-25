# Motion spec — the Slam Card

Extracted from round-1 concept `editorial.html`, whose verdict was: **the
animation is the best of the four ("basically cinematic"), the typography and UI
choices are atrocious.** Bogdan asked specifically for this transition — the one
that plays when you tap agree and when you kill an agent — to be rebuilt in
Kinetic Prime's shell.

**Nothing about Editorial's appearance is inherited. This is motion only.**

## One transition, two pre-rolls

There is a single shared core (`slamCard()`), reached from two unrelated
pre-rolls: the answer flow (Approve/Hold), and the kill flow (hold-to-fill). The
card itself differs between them in only three ways — the word's colour, the
haptic pattern, and what happens after it resolves.

Curves referenced throughout:

- `ease-cine` = `cubic-bezier(0.16, 1, 0.3, 1)`
- `ease-out` = `cubic-bezier(0.23, 1, 0.32, 1)`
- `ease-drawer` = `cubic-bezier(0.32, 0.72, 0, 1)`

---

## Flow A — answering a blocked agent

**Trigger**: tapping one of two options. Both the full-screen cover card and the
inline in-thread question use the same handler.

**There is no shared-element morph here.** The card does not emerge from the
tapped button's position — it is a fixed, position-agnostic full-bleed overlay
that always wipes from the bottom edge regardless of where the option sat. Do not
reach for `matchedGeometryEffect`; there is no continuity to preserve.

### Beat sheet, t=0 at tap

| t (ms) | duration | what happens |
|---|---|---|
| 0 | — | re-entrancy lock set. Chosen option marked, siblings marked dropped. Haptic: single 12 ms pulse. |
| 0 | 620 | chosen option runs `slamGo` |
| 0 | 240 | siblings run `slamDrop` — **finishing 380 ms before the winner does**, so from 240–620 ms the winning option is alone on screen, still growing into the empty space |
| 560 | — | the card fires — **60 ms before `slamGo` finishes**, so the rising wipe overtakes and buries the tail of the button's zoom |
| 560 | 460 | card mask `wipeIn`. Haptic: 10 ms, pause 40, 18 ms |
| 650 | 700 | the word presses in (90 ms delay) — runs to 1350, **330 ms past the wipe's own completion**, so the word keeps settling while the card is already static |
| 890 | 500 | the sub-line fades up (330 ms delay) — runs to 1390 |
| 1390 | **320 dead** | **the held beat. Nothing moves.** |
| 1710 | 400 | `wipeOut` |
| 2110 | — | card gone. Thread rebuilt: question removed, three new messages appended (the decision, the agent's confirmation, its aside) |
| 2110 | 420 | screen cut to the channel |

### Per-element choreography

**`slamGo`** — 620 ms, `ease-cine`, forwards, no delay:
`scale(1)` → `scale(1.42) translateY(-6px)`. **Opacity never drops** — it stays
fully opaque and just grows and lifts.

**`slamDrop`** — 240 ms, `ease-out`, forwards, starts simultaneously:
→ `translateY(22px)`, `opacity: 0`, `blur(7px)`.

**Card mask** — `ease-cine` both ways:
- in: `inset(100% 0 0 0)` → `inset(0 0 0 0)`, 460 ms
- out: `inset(0 0 0 0)` → `inset(0 0 100% 0)`, 400 ms

Both animate the **bottom** inset, so the reveal boundary travels **upward in
both directions** — a rising curtain that keeps rising rather than reversing
itself. Full-viewport, not scoped to the content block.

**The word** — 700 ms, `ease-cine`, 90 ms delay:
`letter-spacing: .04em → -.055em`, `opacity: 0 → 1`,
`translateY(16px) → 0`. Starts loosely tracked, invisible, offset down; tightens,
fades in, settles.

**The sub-line** — 500 ms, `ease-out`, 330 ms delay:
`opacity: 0 → 1`, `translateY(11px) → 0`.

**The kicker label** has no animation at all — it appears fully formed the
instant it is unmasked.

The mask timeline and the content timeline are **two independently authored
tracks**, not one derived from the other. Keep them that way.

### The screen cut

- outgoing: 260 ms `ease-out` — opacity → 0, `scale(.965)`, `blur(0) → blur(5px)`
- incoming: 420 ms `ease-cine` — opacity → 1, `translateY(20px) scale(.985)` → none
- messages re-enter staggered 52 ms per index

**Quirk worth keeping**: when the answer came from the inline in-thread question,
the destination is the screen you are already looking at, and it *still* replays
its own arrival — every message re-staggers from scratch. A hard self-cut, not a
no-op. It reads as "this is now a new scene" even though nothing navigated.

### What each beat is saying

- **0–620 ms**: ambiguity is eliminated fast (loser gone by 240) while the winner
  keeps growing alone. This is *choice becoming irreversible*, dramatised before
  the system even acknowledges it.
- **560 ms overtake**: the system is already moving on before your own gesture
  finished animating. A deliberately fast handoff, not a polite wait.
- **650–1350 ms**: tracking tightening from loose to tight is the decision
  locking down, typographically.
- **890–1390 ms**: the headline commits, the receipt confirms after.
- **1390–1710 ms**: the load-bearing pause. Nothing moves, forcing the
  confirmation to actually be read rather than flash past. **This is the beat he
  is praising.**
- **exit**: a hard, punctuated return to a conversation that already has
  consequences in it.

### Interrupt

**None.** A hard re-entrancy lock is taken at trigger and released only after the
whole sequence completes. No abort, no undo, no back-gesture. Once tapped it is
atomic.

---

## Flow B — killing an agent

**Trigger**: a control sheet (slides up 440 ms `ease-drawer`, scrim 320 ms
`ease-out` with a 2 px backdrop blur) containing a Kill button and the hint
"Hold. Killing drops unsaved state."

### Pre-roll: hold-to-fill

On press: light 4 ms haptic, and a fill sweeps left→right,
`inset(0 100% 0 0)` → `inset(0 0 0 0)`, **1500 ms, linear**. The fill carries a
duplicate of the button label in ink colour, so the label inverts under the
sweeping boundary — two overlapping same-position labels, one red-on-transparent,
one dark-on-red revealed by the mask.

**Cancel** on release before 1500 ms: the fill retracts from wherever it reached,
**220 ms, ease-out** — a fast asymmetric snap-back against the slow linear fill.
Fully reversible at any point; nothing is sent and no state changes until the
timer completes.

### Beat sheet, t=0 at hold completion

| t (ms) | what |
|---|---|
| 0 | sheet slides down (440 ms), scrim fades (320 ms). Haptic: **18, pause 60, 18, pause 60, 26** — five stages, heavier than the answer flow's single pulse. Agent status set dead in the model. |
| 260 | the same slam card fires, identical timings to Flow A, word in the deep flare colour instead of ink |
| after | header meta text swaps instantly, no animation. If a status flap for that agent exists in the DOM, it rolls to DEAD — 250 ms `ease-out` per character column, columns staggered 26 ms |

**No navigation after a kill.** You stay where you are; only the header and the
row status update in place.

### What it is saying

The 1.5 s linear fill makes destruction hard to do by accident, and is honestly
cancellable the whole way — deliberately contrasting with the instant,
uncancellable commit of the answer tap. The colour inverting under the label
paints the word into its activated state. The heavier five-pulse haptic separates
a destructive act from a routine one purely through touch.

And reusing the *same* card for termination as for a normal decision says
something on purpose: in this app's vocabulary, killed is just another decision —
formally identical to approving, only red.

### Interrupt

Fully cancellable during the hold, zero cost. Once the hold completes it is
atomic, exactly like Flow A.

---

## Reduced motion

Shortened and de-directionalised, **not removed** — the source's own comment says
"gentler, not zero".

- `slamGo`/`slamDrop` → plain opacity crossfades, 200/160 ms
- the 560 ms pre-delay → 200 ms
- the held beat 1150 → 520 ms; post-exit cleanup 400 → 180 ms
- wipes, word press and sub-fade → a flat 220 ms fade with zero delay; **all
  stagger removed**
- kill hold 1500 → 600 ms
- screen cut → 200/160 ms

Same sequence of beats, same order. Every directional transform stripped,
durations compressed ~2.5–3×, stagger gone.

---

## Porting notes for SwiftUI

- **The bottom-up mask wipe** has no stock equivalent. `.transition(.move)` and
  `.push` translate the whole view — content moves — which is the wrong look. This
  keeps content still and grows the visible window. Build a custom `Shape` with
  `revealFraction` as its `animatableData`, apply as `.mask()`, drive with
  `.timingCurve(0.16, 1, 0.3, 1, duration: 0.46)`.
- **Animated tracking on the word** is the risky one. `.tracking()` does not
  reliably interpolate under implicit animation across OS versions and can snap
  between two typeset states. Use a `KeyframeAnimator` driving a numeric tracking
  value, and **verify on device that it actually tweens** rather than jump-cuts.
- **Two independent timelines** — mask reveal and content — implemented as two
  drivers, not one derived from the other, as the source does.
- **Multi-pulse haptics** need Core Haptics; `UIImpactFeedbackGenerator` only
  gives single canned pulses. The patterns are `[10, 40, 18]` for an answer and
  `[18, 60, 18, 60, 26]` for a kill — a clean 1:1 port as discrete events at
  explicit offsets.
- **Hold-to-fill ports cleanly.** `withAnimation(.linear(duration: 1.5))` on
  press, `.easeOut(duration: 0.22)` on early release — SwiftUI animations are
  natively interruptible, so the asymmetric cancel falls out for free. The
  colour-invert is two stacked `Text` views, the top masked to `fill * width`.
- **The card sequence** maps onto a `PhaseAnimator` with three phases — hidden,
  shown, exiting — each driving mask fraction and content opacity, with the held
  beat expressed as the dwell between phases.
- **Do not use `matchedGeometryEffect` here.** Confirmed there is no shared
  geometry in this transition.
