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
