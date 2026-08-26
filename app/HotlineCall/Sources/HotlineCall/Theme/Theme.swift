import SwiftUI

/// Kinetic Prime's tokens, type ramp and radii, read out of `v2-prime.html`
/// rather than invented. Dark only; there is no light variant and no semantic
/// colour indirection, because there is exactly one appearance to serve.
///
/// `nonisolated` on the enum: these are pure `Sendable` values. Shapes and
/// `Animatable` modifiers run off the main actor (see `Motion.swift`) and have
/// to be able to read a colour and a size.
nonisolated enum Theme {

    // MARK: - Ground

    static let bg = rgb(0x08_08_0A)
    static let bgLift = rgb(0x0E_0E_12)
    static let surf = rgb(0x13_13_18)
    static let surf2 = rgb(0x1B_1B_21)

    static let line = Color.white.opacity(0.065)
    static let line2 = Color.white.opacity(0.11)

    // MARK: - Ink

    static let ink = rgb(0xF4_F4_F6)
    static let ink2 = ink.opacity(0.56)
    static let ink3 = ink.opacity(0.30)
    static let ink4 = ink.opacity(0.14)
    static let ink5 = ink.opacity(0.07)

    // MARK: - The one accent

    /// Blocked, and destructive. Nothing else is allowed to use it.
    static let sig = rgb(0xFF_4A_1E)
    /// Text on a blocked row -- `sig` itself is unreadable at body weight.
    static let sigLift = rgb(0xFF_B0_9A)
    static let sig20 = sig.opacity(0.20)
    static let sig12 = sig.opacity(0.12)
    static let sig10 = sig.opacity(0.10)
    static let sig06 = sig.opacity(0.06)

    // MARK: - Radii

    static let cardRadius: Double = 14
    static let bubbleRadius: Double = 18
    /// A pill, expressed the way the prototype does. Clamped by the shape.
    static let pillRadius: Double = 999

    // MARK: - Geometry

    /// The gutter every screen shares. The left 44 pt of a channel belongs to
    /// the back gesture (APP-PLAN 4.7), so nothing interactive may sit inside
    /// it that is not the back affordance itself.
    static let edge: Double = 20
    static let backStrip: Double = 44

    // MARK: - Type
    //
    // The design rests on Geist's tracking and its tabular figures, and Geist is
    // bundled (APP-PLAN 12.4, `Fonts.swift`).

    /// **The one-line fallback.** Set this to `nil` and every call site below
    /// goes back to SF with the tracking table applied unchanged -- APP-PLAN
    /// 4.1's named fallback, and the density holds. It is kept because the
    /// resource-plus-registration path cannot be verified without the device:
    /// if the face does not come through, this is the whole edit.
    static let family: String? = "Geist"

    static func font(_ style: TextStyle) -> Font {
        if let face = Fonts.face(for: style.weight) {
            .custom(face, fixedSize: style.size)
        } else {
            .system(size: style.size, weight: style.weight)
        }
    }

    // MARK: -

    private static func rgb(_ packed: UInt32) -> Color {
        Color(
            red: Double((packed >> 16) & 0xFF) / 255,
            green: Double((packed >> 8) & 0xFF) / 255,
            blue: Double(packed & 0xFF) / 255
        )
    }
}

/// One row of APP-PLAN 4.1's type ramp.
///
/// Tracking is stored in **em** because that is how the table is written and
/// how it stays right when a size changes; `tracking` converts to the points
/// SwiftUI wants.
nonisolated struct TextStyle: Hashable, Sendable {
    let size: Double
    let weight: Font.Weight
    let em: Double
    /// A multiple of the size, as CSS line-height. `nil` leaves it default.
    let lineHeight: Double?

    init(_ size: Double, _ weight: Font.Weight, em: Double, lineHeight: Double? = nil) {
        self.size = size
        self.weight = weight
        self.em = em
        self.lineHeight = lineHeight
    }

    var tracking: Double { size * em }

    /// SwiftUI's `lineSpacing` is the gap *between* lines, not the line box.
    var lineSpacing: Double { ((lineHeight ?? 1) - 1) * size }

    static let wordmark = TextStyle(34, .semibold, em: -0.035)
    static let screenTitle = TextStyle(28, .semibold, em: -0.032)
    static let slamWord = TextStyle(44, .bold, em: 0)          // animated, see 9.4
    static let rowName = TextStyle(17, .semibold, em: -0.018)
    static let body = TextStyle(15.5, .regular, em: -0.012, lineHeight: 1.42)
    static let rowSubtitle = TextStyle(13.5, .regular, em: -0.008)
    static let cellValue = TextStyle(15, .semibold, em: -0.025)
    /// The unit beside a cell's number. Telemetry sets the two at different
    /// weights on a shared baseline -- `0` carries the reading and `tok/s` only
    /// says what it is -- so a strip of four scans as four numbers rather than
    /// four strings. It is lowercase, so it takes none of `label`'s tracking.
    static let cellUnit = TextStyle(10.5, .regular, em: -0.005)
    /// The tool's name in a thread row. Mixed case in full ink against the
    /// call in `ink2`: the name is the thing being scanned for, the arguments
    /// are detail. `label` would set it uppercase and flatten that.
    static let toolName = TextStyle(13.5, .semibold, em: -0.008)

    /// The uppercase label row: 9.5-11 pt at +0.09 to +0.15 em. Tracking rises
    /// with size across that range, which is what keeps the smallest labels
    /// from setting solid.
    static func label(_ size: Double) -> TextStyle {
        let t = clamp((size - 9.5) / 1.5, 0, 1)
        return TextStyle(size, .semibold, em: lerp(0.09, 0.15, t))
    }
}

extension View {
    /// Font, tracking and leading in one place, so no call site can apply two
    /// of the three and quietly lose the density.
    func text(_ style: TextStyle) -> some View {
        font(Theme.font(style))
            .tracking(style.tracking)
            .lineSpacing(style.lineSpacing)
    }
}

/// The layer order of APP-PLAN 2.1, as one table rather than magic numbers
/// scattered over `Shell`.
///
/// Map, sheet and slam have no view yet -- they are steps 8, 10 and 9. Their
/// slots are named here so that adding one is a `zIndex(Z.map)` and not a
/// re-derivation of the whole stack.
nonisolated enum Z {
    static let fleet: Double = 10
    static let scrim: Double = 15
    static let channel: Double = 20
    static let map: Double = 30
    static let sheet: Double = 40
    static let overlay: Double = 50
    static let hero: Double = 55
    static let slam: Double = 70
}

/// Named coordinate spaces. `nonisolated` because `onGeometryChange`'s `of:`
/// transform is `@Sendable` and reads one of these.
nonisolated enum Space {
    static let list = "fleet.list"
    static let shell = "shell"
}
