import Foundation

// The motion system's arithmetic, with no SwiftUI in it.
//
// It lives in its own file for the reason `Wire/Rules.swift` does: there is no
// Mac, no simulator and no way to execute SwiftUI on the box this app is built
// on, but a file that imports only Foundation compiles and **runs** natively on
// Linux with the same toolchain (`docs/BUILDING.md`). Every number below is
// therefore executed by `app/wiretest/run.sh` rather than asserted -- including
// the rubber-band inverse, which is the one that fails silently and puts a
// visible step under the thumb when it is wrong.
//
// `nonisolated` throughout: `Shape.path(in:)` and `Animatable.animatableData`
// are called off the main actor and every one of these is reachable from there.
// They are pure functions of their arguments, so that is also simply the
// truthful annotation.

nonisolated func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(v, lo), hi)
}

nonisolated func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
    a + (b - a) * t
}

/// A smoothstep window over the master progress value, ported verbatim from
/// `v2-prime.html`.
///
/// The softening is per element. **The master `nav` stays linear**, which is
/// what lets a drag-back track the finger 1:1 while every staged element still
/// eases in and out of its own slot.
nonisolated func win(_ e: Double, _ start: Double, _ span: Double) -> Double {
    let t = clamp((e - start) / span, 0, 1)
    return t * t * (3 - 2 * t)
}

/// iOS rubber-banding. `over` is how far past the edge, `dim` the dimension it
/// is resisted against; the result asymptotes to `dim`, so no finger travel can
/// pull the surface off the screen.
nonisolated func rubber(_ over: Double, _ dim: Double, _ c: Double = 0.55) -> Double {
    (over * dim * c) / (dim + c * abs(over))
}

/// The inverse of `rubber`, which exists for one reason: a drag that *begins*
/// while the surface is already banded out must resume from the finger-space
/// value, not band a banded number. Without it, grabbing a bouncing list puts a
/// visible step under the thumb.
nonisolated func unrubber(_ banded: Double, _ dim: Double, _ c: Double = 0.55) -> Double {
    let b = abs(banded)
    guard b < dim else { return banded }
    return (banded < 0 ? -1 : 1) * (b * dim) / (c * (dim - b))
}

/// Where a fling is going, using the same exponential-decay projection the
/// system uses for scroll deceleration -- so a throw here decides at the same
/// threshold a throw anywhere else on the phone does.
///
/// `(v/1000) * 0.998 / (1 - 0.998)` = `v * 0.499`.
nonisolated func project(_ velocity: Double) -> Double { velocity * 0.499 }

// MARK: - Seams

/// Where a seam lands when the finger lets go.
///
/// **Every seam in this app is a 0...1 scalar that comes to rest at exactly 0 or
/// exactly 1.** There is no third resting state, and the reason is not
/// tidiness: a panel that rests half-open is drawn over the screen it was
/// pulled out of, and on this build neither of the two was usable while it was
/// -- the map's own recognizer is armed above 0.5 and the channel's below it, so
/// a scalar parked at 0.5 belonged to nobody.
///
/// It is a free function so `app/wiretest/run.sh` can execute the invariant:
/// no `(progress, velocity)` pair produces anything other than 0 or 1.
nonisolated func seamTarget(_ progress: Double, velocity: Double, commit: Double) -> Double {
    progress + project(velocity) < commit ? 0 : 1
}

// MARK: - The fleet list's row swipe

nonisolated enum SwipeOutcome: String, Sendable, Hashable {
    /// Fire the first left capability -- `stop` in the server's order, and a
    /// fling only ever commits the reversible one (APP-PLAN 4.7).
    case fireLeft
    case fireRight
    case openLeft
    case openRight
    case closed
}

/// APP-PLAN 4.7's row-swipe table, as a function rather than as four `if`s
/// buried in a gesture that cannot be executed on this box.
///
/// **Why the commit test is the release *position* and not the projected end.**
/// `project(v) = 0.499·v` is the scroll deceleration projection: right for a
/// fling that travels hundreds of points, wrong by an order of magnitude for a
/// drawer 118 to 148 pt deep. With the row open at its limit, the table's
/// `end < -lim - 74` needed only `v < -148 pt/s` -- slower than any deliberate
/// swipe -- so simply *opening* the row fired `stop`, and opening it the other
/// way fired `retask`. That is the whole of "the swipe just does stuff".
///
/// The same arithmetic made the fling clause unreachable: whenever
/// `v < -1100` and `x < -60`, the projected end is already below -609 and the
/// first clause had therefore always fired. The table means the two as "he
/// swiped it all the way" and "he flung it"; as written the first subsumed the
/// second. Position restores the split, and the fling clause is doing its job
/// again.
///
/// Opening still reads the projected end, because whether he *meant* to leave
/// the row open genuinely is a momentum question.
nonisolated func swipeOutcome(x: Double, velocity: Double,
                              leftLimit: Double, rightLimit: Double) -> SwipeOutcome {
    if leftLimit > 0, x < -leftLimit - 74 || (velocity < -1100 && x < -60) { return .fireLeft }
    if rightLimit > 0, x > rightLimit + 66 || (velocity > 1100 && x > 50) { return .fireRight }
    let end = x + project(velocity)
    if leftLimit > 0, end < -leftLimit * 0.62 { return .openLeft }
    if rightLimit > 0, end > 74 { return .openRight }
    return .closed
}

// MARK: - The map's focus band

/// How open the phase whose top edge is at `top` should be (APP-PLAN 6.2).
///
/// The band sits 170 pt down the map and reaches 210 pt either side, so exactly
/// one phase is ever fully open and its neighbours are visibly on their way in.
nonisolated func focusBand(top: Double, band: Double = 170, reach: Double = 210) -> Double {
    clamp(1 - abs(top - band) / reach, 0, 1)
}

/// The per-tool-row stagger inside an opening phase: `clamp((on - k*0.055)/0.6, 0, 1)`.
nonisolated func toolStagger(_ on: Double, _ k: Int) -> Double {
    clamp((on - Double(k) * 0.055) / 0.6, 0, 1)
}
