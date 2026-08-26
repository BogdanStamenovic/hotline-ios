import SwiftUI

/// The commit transition (APP-PLAN 9, `docs/MOTION-SLAM-CARD.md`).
///
/// One shared card, reached from two unrelated pre-rolls that differ in exactly
/// three ways: **the word's colour, the haptic pattern, and what happens after
/// it resolves.** Reusing the same card for deletion as for a normal decision
/// says something on purpose: in this app's vocabulary, killed is just another
/// decision -- formally identical to approving, only red.
///
/// ### What it is not
///
/// - **No shared-element morph.** The card is a fixed, position-agnostic
///   full-bleed overlay that always wipes from the bottom edge regardless of
///   where the control that triggered it sat. `matchedGeometryEffect` is not
///   used here or anywhere else in this app.
/// - **Not spring-driven.** Every curve is a cubic-bézier authored against the
///   others to the millisecond. Re-expressing them as springs would destroy the
///   two things that make it work: the 560 ms overtake and the 320 ms held beat.
/// - **Not scrubbable and not reversible.** It sits *above* Kinetic's scene
///   system with its own lifecycle rather than being folded into it. Folding an
///   atomic sequence into a reversible progress value gives one of two bad
///   outcomes: the card becomes scrubbable and stops being a commitment, or
///   `nav` grows a mode in which it refuses to move, which is a lie about what a
///   progress value is.
enum SlamFlow: Equatable, Sendable {
    case answer, kill, purge

    /// Answer is ink; kill and purge are `sig`.
    var isDestructive: Bool { self != .answer }

    var pattern: Haptics.Pattern {
        self == .answer ? Haptics.answer : Haptics.kill
    }
}

/// One atomic run, and the lock. `nil` means nothing is committed.
///
/// It is `@State` on `Shell` because **it is a property of the presentation,
/// not of the data**: nothing on the server changes because a card is on screen.
struct AtomicRun: Identifiable, Equatable {
    let id = UUID()
    let flow: SlamFlow
    let word: String
    /// The chosen option's own label for an answer, the dry-run counts for a
    /// purge. Never invented: it is what he actually committed to.
    let sub: String
    let kicker: String
    /// The channel whose feed has to be parked. `nil` for a purge of an agent
    /// with no open channel.
    let agent: AgentID?
}

// MARK: - The mask

/// **No stock transition does this.** `.transition(.move)` and `.push` translate
/// the whole view -- the content moves -- which is the wrong look. Here the
/// content stays still and the *visible window* grows.
///
/// **Both boundaries travel upward.** In: `topInset` 1 -> 0, the band's top edge
/// travelling from the bottom of the screen to the top. Out: `bottomInset`
/// 0 -> 1, the band's bottom edge doing the same. It is a rising curtain that
/// keeps rising rather than reversing itself, and getting this backwards is the
/// single easiest way to lose the effect while the code still "works".
nonisolated struct InsetReveal: Shape {
    var topInset: Double
    var bottomInset: Double

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

/// Animated tracking, owned as `animatableData` so SwiftUI interpolates the
/// number and re-typesets each frame.
///
/// **This is the highest-risk line in the port, because it fails silently.**
/// A bare `.tracking()` on an animated value does not reliably interpolate
/// across OS versions and can jump-cut between two typeset states: the word
/// still appears, it just stops being the decision locking down typographically.
nonisolated struct Tracked: ViewModifier, Animatable {
    var value: Double

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    @MainActor func body(content: Content) -> some View {
        content.tracking(value)
    }
}

// MARK: - The card

struct SlamLayer: View {
    let run: AtomicRun
    /// The three independently authored tracks. **The mask timeline and the
    /// content timeline are two tracks, not one derived from the other** -- that
    /// is what lets the word keep settling 330 ms after the wipe has finished.
    let reveal: Double
    let exit: Double
    let wordIn: Double
    let subIn: Double
    let mo: Double

    /// 44 pt / 700. Tracking runs +0.04 em -> -0.055 em, in points.
    private static let size: Double = 44
    private static let looseTracking = 0.04 * size
    private static let tightTracking = -0.055 * size

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Spacer(minLength: 0)
                // **The kicker has no animation at all** -- it appears fully
                // formed the instant it is unmasked. Do not add one.
                Text(run.kicker.uppercased())
                    .text(.label(10))
                    .foregroundStyle(Theme.ink3)

                word

                Text(run.sub)
                    .text(.body)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(3)
                    .opacity(subIn)
                    .offset(y: (1 - subIn) * 11 * mo)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edge + 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Applied over the full viewport, not scoped to the content block.
        .mask { InsetReveal(topInset: 1 - reveal, bottomInset: exit) }
        .ignoresSafeArea()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(run.word). \(run.sub)")
        .accessibilityAddTraits(.isStaticText)
    }

    /// APP-PLAN 9.6's two branches, behind one constant, exactly as the hero
    /// title's are (`Flight.perGlyph`).
    @ViewBuilder
    private var word: some View {
        if Flight.perGlyph {
            SlamGlyphs(word: run.word, tint: tint, tracking: tracking, mo: mo)
        } else {
            Text(run.word)
                .font(Theme.font(.slamWord))
                .foregroundStyle(tint)
                .modifier(Tracked(value: tracking))
                .opacity(wordIn)
                .offset(y: (1 - wordIn) * 16 * mo)
                .fixedSize()
        }
    }

    private var tint: Color { run.flow.isDestructive ? Theme.sig : Theme.ink }

    /// Loose to tight, as the decision locks down. Under Reduce Motion there is
    /// no tracking animation at all -- the word is simply set tight.
    private var tracking: Double {
        mo == 0 ? Self.tightTracking : lerp(Self.looseTracking, Self.tightTracking, wordIn)
    }
}

/// APP-PLAN 9.6's decided-in-advance fallback: one `Text` per glyph with the
/// tracking applied as spacing, so positions interpolate and nothing is
/// re-typeset.
///
/// It costs the kerning pairs, which is acceptable for one uppercase word and
/// unacceptable for body text -- which is exactly why it is scoped to the slam
/// word and the hero title and to nothing else.
///
/// **The verification that decides which branch ships has not been run**: it
/// needs a phone, a 60 fps screen recording and a frame stepper (set the word to
/// `COMPACTED`, step t = 650...1350 ms, count distinct rendered widths; pass at
/// >= 8, fail at <= 2). Both branches are implemented and `Flight.perGlyph` is
/// the one-line switch.
private struct SlamGlyphs: View {
    let word: String
    let tint: Color
    let tracking: Double
    let mo: Double

    var body: some View {
        HStack(spacing: tracking) {
            ForEach(Array(word.enumerated()), id: \.offset) { _, character in
                Text(String(character))
                    .font(Theme.font(.slamWord))
                    .foregroundStyle(tint)
            }
        }
        .fixedSize()
    }
}

// MARK: - Flow A's pre-roll

/// The answer card: what a blocked agent asked, and the commit that answers it.
///
/// **Deliberate deviation from APP-PLAN 9.5, and the reason for it.** The plan's
/// pre-roll has a chosen option growing while its *siblings* drop away, and the
/// card's sub-line is "the chosen option's own label". There are no options on
/// this wire. `/api/v1/conversations` carries `asked` as free text and nothing
/// else -- no daemon anywhere in `server/` has a concept of offered choices --
/// so rendering Approve/Hold buttons would be fabricating a decision the agent
/// never offered, which §9.1's rule forbids as loudly as a fabricated readout.
///
/// So: the card itself is the thing that runs `slamGo`, `slamDrop` has nothing
/// to drop and its 240 ms window is simply empty, and the sub-line is **his own
/// answer** -- which is the true analogue of "what he committed to". Every
/// timing after t = 0 is unchanged, including the 560 ms overtake, because the
/// card fires on a clock rather than on the pre-roll finishing.
struct AnswerCard: View {
    let question: String
    /// When it started waiting -- `blockedSince` from the roster, or the
    /// conversation's own open time. The cost line is exact and ticks live;
    /// with neither timestamp there is no clock rather than one started at zero.
    let blockedSince: Date?
    let committing: Bool
    let onCommit: (String) -> Void

    @State private var draft = ""
    @State private var drag: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Releasing past 0.62 x width, or with vx > 900 past 60 pt, commits.
    private static let commitFraction: Double = 0.62

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("WAITING ON YOU")
                    .text(.label(10))
                    .foregroundStyle(Theme.sig)
                Spacer(minLength: 0)
                if let since = blockedSince {
                    // "Idle since 09:57 · 4:12 of wall clock burned", ticking.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(costLine(now: context.date, since: since))
                            .text(.label(9.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }

            Text(question)
                .text(.body)
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)

            TextField("Answer", text: $draft, axis: .vertical)
                .text(.body)
                .foregroundStyle(Theme.ink)
                .tint(Theme.sig)
                .lineLimit(1...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))

            rail
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.surf)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.sig20, lineWidth: 1))
        )
        // `slamGo`: scale 1 -> 1.42 with a 6 pt lift, and **opacity never
        // drops** -- it grows and lifts, fully opaque, into the space the card
        // is about to bury.
        .scaleEffect(committing && !reduceMotion ? 1.42 : 1, anchor: .center)
        .offset(y: committing && !reduceMotion ? -6 : 0)
        .animation(committing
                   ? (reduceMotion ? .easeOut(duration: 0.2)
                                   : .timingCurve(0.16, 1, 0.3, 1, duration: 0.62))
                   : nil,
                   value: committing)
    }

    /// Prime's drag-right commit, with `whip` filling it the rest of the way.
    /// **That release is t = 0** for the whole beat sheet.
    private var rail: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sig20)
                Capsule()
                    .fill(Theme.sig)
                    .frame(width: max(0, geo.size.width * clamp(drag, 0, 1)))
                Text(ready ? "SLIDE TO SEND" : "TYPE AN ANSWER")
                    .text(.label(10))
                    .foregroundStyle(ready ? Theme.ink : Theme.ink3)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 38)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard ready else { return }
                        drag = clamp(value.translation.width / max(geo.size.width, 1), 0, 1)
                    }
                    .onEnded { value in
                        guard ready else { return }
                        let past = value.translation.width
                        if drag > Self.commitFraction
                            || (value.velocity.width > 900 && past > 60) {
                            withAnimation(.whip) { drag = 1 }
                            let text = draft
                            draft = ""
                            onCommit(text)
                        } else {
                            withAnimation(.snap) { drag = 0 }
                        }
                    }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Send answer")
            .accessibilityAction {
                let text = draft
                draft = ""
                onCommit(text)
            }
        }
        .frame(height: 38)
    }

    private var ready: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func costLine(now: Date, since: Date) -> String {
        "\(hotlineClock(now.timeIntervalSince(since))) OF WALL CLOCK BURNED"
    }
}
