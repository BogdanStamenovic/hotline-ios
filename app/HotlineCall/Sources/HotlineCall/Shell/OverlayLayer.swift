import SwiftUI

/// Chrome that belongs to no screen: the flying title, the reachability
/// banner, the coach toast.
struct OverlayLayer: View {
    let hero: Agent?
    let nav: Double
    let mo: Double
    let from: CGRect
    let reachable: Reachability
    let toast: Toast?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Mounted for the whole transition, in both directions. Gating
            // this on `nav` would gate it on the *model* value, which
            // `withAnimation` sets to its target immediately -- so the copy
            // would never be built on the way in and would linger on the way
            // out. Its visibility is a term inside `Flight`, where the
            // interpolated value actually reaches.
            if let hero, mo != 0, from != .zero {
                HeroTitle(name: hero.name, e: nav, from: from)
                    .zIndex(Z.hero)
            }

            VStack(spacing: 8) {
                if case .stale(let since, let why) = reachable {
                    StaleBanner(since: since, why: why)
                }
                Spacer(minLength: 0)
                if let toast {
                    ToastView(text: toast.text)
                        .id(toast.id)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, 10)
            .animation(.enter, value: reachable)
            .animation(.enter, value: toast)
        }
        .allowsHitTesting(false)
    }
}

/// Where the channel's header title sits. Shared by the travelling copy and
/// the real label so the handover cannot drift apart in an edit.
nonisolated enum HeroDestination {
    static let x: Double = 24
    static let y: Double = 98
    static var point: CGPoint { CGPoint(x: x, y: y) }
}

// MARK: - The hero title

/// The agent's name is **one object travelling between two screens**, not two
/// labels crossfading.
///
/// `matchedGeometryEffect` is not used here, or anywhere else in this app: it
/// owns its own interpolation and cannot be scrubbed by an external progress
/// value, which is the entire mechanism of APP-PLAN 4.3.
private struct HeroTitle: View {
    let name: String
    let e: Double
    let from: CGRect


    var body: some View {
        Group {
            if Flight.perGlyph {
                GlyphRow(name: name, e: e)
            } else {
                Text(name)
                    .text(.rowName)
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
        }
        .modifier(Flight(e: e, from: from, to: HeroDestination.point))
    }
}

/// The flight, as an `Animatable` modifier so SwiftUI interpolates `e` itself
/// and re-evaluates `body` per frame.
///
/// **The animated tracking is the highest-risk line in this port**, because it
/// fails silently: `.tracking()` under implicit animation does not reliably
/// interpolate across OS versions and can jump-cut between two typeset states.
/// Owning `e` as `animatableData` and computing tracking inside `body` is what
/// forces a re-typeset per frame rather than an interpolation between two
/// endpoints.
///
/// **APP-PLAN 9.6's verification, which decides `perGlyph`:** screen-record the
/// transition at 60 fps and step frame by frame across the flight; count the
/// frames on which the rendered width of the name changes. Pass at >= 8
/// distinct widths, fail at <= 2. On a fail, set `perGlyph = true` -- the
/// pre-decided fallback, which interpolates glyph positions instead of
/// re-typesetting and cannot jump-cut. It costs the kerning pairs, which is
/// acceptable for one short name and is why it is scoped to this label and the
/// slam word alone.
nonisolated struct Flight: ViewModifier, Animatable {
    /// Not yet run: the procedure needs a phone, a screen recording and a frame
    /// stepper. Flipping this is a one-line change and no other code moves.
    static let perGlyph = false

    var e: Double
    let from: CGRect
    let to: CGPoint

    var animatableData: Double {
        get { e }
        set { e = newValue }
    }

    /// The shared element leads: it arrives before the world assembles.
    private var ef: Double { clamp(e / 0.82, 0, 1) }

    /// 17 pt row name -> 28 pt screen title.
    static let growth = 28.0 / 17.0

    /// Tracking is interpolated too, and **divided by the scale** -- otherwise
    /// it grows with the glyphs and the header title reads loose.
    static func tracking(_ ef: Double, scale: Double) -> Double {
        lerp(17 * -0.018, 28 * -0.032, ef) / scale
    }

    @MainActor func body(content: Content) -> some View {
        let ef = ef
        let scale = lerp(1, Self.growth, ef)
        return content
            .tracking(Self.tracking(ef, scale: scale))
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: lerp(from.minX, to.x, ef), y: lerp(from.minY, to.y, ef))
            // The handover: the copy hides at e > 0.88 and the real title's
            // opacity goes to 1 at the same instant. Below 0.008 the row's own
            // name has not been hidden yet, so a second one here would double.
            .opacity(e > 0.88 || e < 0.008 ? 0 : 1)
    }
}

/// APP-PLAN 9.6's fallback. One `Text` per character with the tracking applied
/// as spacing, so positions interpolate and nothing is re-typeset.
private struct GlyphRow: View, Animatable {
    let name: String
    var e: Double

    var animatableData: Double {
        get { e }
        set { e = newValue }
    }

    var body: some View {
        let ef = clamp(e / 0.82, 0, 1)
        let scale = lerp(1, Flight.growth, ef)
        HStack(spacing: Flight.tracking(ef, scale: scale)) {
            ForEach(Array(name.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .text(.rowName)
                    .foregroundStyle(Theme.ink)
            }
        }
        .fixedSize()
    }
}

// MARK: - Banners

/// The roster on screen is not the roster on archserver, and it says so with
/// the time it stopped being true rather than a spinner that implies progress.
private struct StaleBanner: View {
    let since: Date?
    let why: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.sig).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(since.map { "SHOWING \(ago($0).uppercased()) OLD DATA" }
                     ?? "CAN'T REACH ARCHSERVER")
                    .text(.label(9.5))
                    .foregroundStyle(Theme.sig)
                Text(why)
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.surf)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.sig20, lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .text(.rowSubtitle)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.surf2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .stroke(Theme.line2, lineWidth: 1))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
