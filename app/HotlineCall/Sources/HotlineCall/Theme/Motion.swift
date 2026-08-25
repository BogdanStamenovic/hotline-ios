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

// MARK: - The scene change

/// What one staged element looks like at one value of `nav`.
///
/// A value rather than a pile of modifiers so the whole staging table is data:
/// `Role.effect` is a pure function that can be read top to bottom against
/// APP-PLAN 4.3, and `Staged.body` has exactly one code path.
nonisolated struct Effect: Hashable, Sendable {
    var opacity: Double = 1
    var offsetY: Double = 0
    var scaleX: Double = 1
    var scaleY: Double = 1
    var anchor: UnitPoint = .center
    var blur: Double = 0
    var hitTesting: Bool = true
}

/// Every element of the list -> channel transition, as its position in
/// APP-PLAN 4.3's staging table.
nonisolated enum Role: Hashable, Sendable {
    case fleet
    case scrim
    /// The row that was tapped. It does not travel -- it dissolves where it
    /// stands while its name is lifted out of it by the hero flight.
    case heroRow
    /// Every other row, `d` signed rows away from the hero.
    case row(d: Int)
    case channel
    case accentRule
    /// The chrome that stages in on its own window: back chevron (0.28),
    /// phase chip (0.42), state line (0.48), strip cell i (0.44 + i*0.026).
    case chrome(start: Double, span: Double)
    case composer
    /// Message `k` from the bottom; 0 is the newest and arrives first.
    case message(k: Int)

    static let backChevron = Role.chrome(start: 0.28, span: 0.42)
    static let phaseChip = Role.chrome(start: 0.42, span: 0.42)
    static let stateLine = Role.chrome(start: 0.48, span: 0.42)
    static func stripCell(_ i: Int) -> Role { .chrome(start: 0.44 + Double(i) * 0.026, span: 0.42) }

    /// `mo` is 1 normally and 0 under Reduce Motion. It multiplies every
    /// positional term, so the staging survives as pure opacity.
    func effect(_ e: Double, _ mo: Double) -> Effect {
        switch self {
        case .fleet:
            let s = 1 - 0.055 * e * mo
            return Effect(opacity: 1 - 0.45 * e, offsetY: -10 * e * mo,
                          scaleX: s, scaleY: s, anchor: UnitPoint(x: 0.5, y: 0.4))

        case .scrim:
            return Effect(opacity: 0.52 * e, hitTesting: false)

        case .heroRow:
            let p = win(e, 0, 0.30)
            return Effect(opacity: 1 - p, blur: (p * 4).rounded())

        case .row(let d):
            let p = win(e, Double(abs(d)) * 0.042, 0.5)
            let travel = Double(d < 0 ? -1 : 1) * p * (118 + Double(abs(d)) * 44) * mo
            return Effect(opacity: 1 - p, offsetY: travel)

        case .channel:
            let s = 1 - (1 - e) * 0.028 * mo
            return Effect(opacity: clamp(e / 0.42, 0, 1), offsetY: (1 - e) * 30 * mo,
                          scaleX: s, scaleY: s, hitTesting: e > 0.55)

        case .accentRule:
            return Effect(scaleX: win(e, 0.06, 0.5), anchor: .leading)

        case .chrome(let start, let span):
            let p = win(e, start, span)
            return Effect(opacity: p, offsetY: (1 - p) * 15 * mo)

        case .composer:
            let cp = win(e, 0.36, 0.5)
            return Effect(opacity: cp, offsetY: (1 - cp) * 74 * mo)

        case .message(let k):
            // Capped at 12: beyond the first screenful the stagger is dropped
            // entirely, or the window for the newest message compresses to
            // nothing on a 400-message channel.
            let q = win(e, 0.24 + Double(min(k, 12)) * 0.030, 0.44)
            return Effect(opacity: q, offsetY: (1 - q) * 28 * mo,
                          blur: ((1 - q) * 4).rounded())
        }
    }
}

/// The scene-change modifier.
///
/// `nonisolated` so `animatableData` can satisfy the protocol's nonisolated
/// requirement under main-actor-by-default; `body` is re-annotated because
/// building a `View` is main-actor work. Everything `body` needs arrives as a
/// stored value -- it cannot reach out to main-actor state, and that is the
/// point of the annotation rather than a workaround for it.
///
/// Conforming to `Animatable` is what makes SwiftUI interpolate `nav` itself,
/// frame by frame, and re-evaluate this `body` at each value. Without it every
/// derived opacity and offset would be interpolated linearly between its own
/// endpoints and the staging windows would silently flatten out.
nonisolated struct Staged: ViewModifier, Animatable {
    var e: Double
    let role: Role
    let mo: Double

    var animatableData: Double {
        get { e }
        set { e = newValue }
    }

    @MainActor func body(content: Content) -> some View {
        let fx = role.effect(e, mo)
        return content
            .blur(radius: fx.blur)
            .scaleEffect(x: fx.scaleX, y: fx.scaleY, anchor: fx.anchor)
            .opacity(fx.opacity)
            .offset(y: fx.offsetY)
            .allowsHitTesting(fx.hitTesting)
    }
}

extension View {
    func staged(_ role: Role, _ e: Double, _ mo: Double) -> some View {
        modifier(Staged(e: e, role: role, mo: mo))
    }
}
