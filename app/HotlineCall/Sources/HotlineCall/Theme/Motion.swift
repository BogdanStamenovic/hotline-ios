import SwiftUI

// MARK: - Scalar helpers
//
// `nonisolated` throughout: `Shape.path(in:)` and `Animatable.animatableData`
// are called off the main actor and every one of these is reachable from
// there. They are pure functions of their arguments, so that is also simply
// the truthful annotation.

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

// MARK: - The springs
//
// `v2-prime.html` integrates a mass-spring-damper with m = 1 at a fixed 1/240 s
// substep. `interpolatingSpring(mass:stiffness:damping:)` is the same model with
// the same parameterisation, so k and c pass through unchanged and nothing is
// lost in translation.

nonisolated extension Animation {
    /// Row snap-back, commit, every FLIP. w0 19.49, z 0.821.
    static let snap = Animation.interpolatingSpring(mass: 1, stiffness: 380, damping: 32)
    /// The forward scene change, scroll settle. w0 14.83, z 1.011.
    static let glide = Animation.interpolatingSpring(mass: 1, stiffness: 220, damping: 30)
    /// The reverse: same path, ~30% faster. Entering is deliberate; leaving is
    /// the system answering, and a slow exit reads as lag.
    static let navBack = Animation.interpolatingSpring(mass: 1, stiffness: 300, damping: 34)
    /// Small offsets, press states. w0 22.80, z 1.009.
    static let settle = Animation.interpolatingSpring(mass: 1, stiffness: 520, damping: 46)
    /// The rows parting: slow, heavy. w0 10.95.
    static let float = Animation.interpolatingSpring(mass: 1, stiffness: 120, damping: 18)
    /// The blocked row: fast, slight overshoot. w0 18.44.
    ///
    /// The `climb`/`float` pair is load-bearing and must not be collapsed into
    /// one spring: the blocked row climbs at w0 18.4 while the rows it passes
    /// part at w0 11.0, and watching it jump the queue rather than the queue
    /// tidily re-sorting is the whole point of APP-PLAN 4.6.
    static let climb = Animation.interpolatingSpring(mass: 1, stiffness: 340, damping: 26)
    /// Staged entrances. w0 13.42.
    static let enter = Animation.interpolatingSpring(mass: 1, stiffness: 180, damping: 26)
    /// The one bouncy spring -- answer commit only. w0 26.46, z 0.643.
    static let whip = Animation.interpolatingSpring(mass: 1, stiffness: 700, damping: 34)
    /// The in-channel readouts. w0 16.13.
    static let meter = Animation.interpolatingSpring(mass: 1, stiffness: 260, damping: 26)
}
