import SwiftUI

/// The transcript: server truth, then this phone's own notes, then the bubbles
/// it is still waiting to hear back about.
///
/// **The optimistic echo is a separate array and is rendered separately.** It
/// is never merged into `moments`, so no code path here or in `Channel` has any
/// reason to compare one message's text with another's -- which is bug 3
/// removed rather than patched.
///
/// **Why this is not a `ScrollView`.** Per-surface meaning for a pull past the
/// top (APP-PLAN 4.7): here it loads older history, on the fleet list it hard
/// refreshes. A `ScrollView`'s `.refreshable` gives one gesture with one look,
/// and it fights a custom recognizer for the ambiguous first few points.
///
/// **What it deliberately does not do: virtualise.** Message heights are not
/// known until they are laid out, so an absolutely-placed list would need a
/// measurement pass that visibly settles on the first frame. The mounted set is
/// bounded instead by what has actually been fetched -- 200 on open, and 200
/// more per explicit pull.
struct ThreadView: View {
    let channel: Channel
    let nav: Double
    let mo: Double
    let onRetry: (Channel.Pending.ID) -> Void
    /// APP-PLAN 7.4's `resumed: false` path. It sits with the record of what
    /// happened rather than in a toast, because that is where he will look.
    let onContinue: () -> Void

    @State private var scroll: Double = 0
    @State private var start: Double = 0
    @State private var dragging = false
    @State private var content: Double = 0
    @State private var viewport: Double = 0
    @State private var armed = false

    /// How far a pull past the top must project before it means "older".
    private static let pullThreshold: Double = 74

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.bg

                if scroll > 4 {
                    PullHeader(text: headerText, armed: armed && channel.hasOlder)
                        .frame(width: geo.size.width, height: max(scroll, 0))
                }

                rows
                    .frame(width: geo.size.width, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        grow(to: height, viewport: geo.size.height)
                    }
                    .offset(y: scroll)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(arbiter(geo.size.height))
            .accessibilityScrollAction { edge in
                let page = geo.size.height * 0.8
                settle(to: clampScroll(scroll + (edge == .top ? page : -page)),
                       velocity: 0, spring: (520, 46))
            }
            .onAppear { viewport = geo.size.height }
        }
    }

    // MARK: - Rows

    private var rows: some View {
        VStack(alignment: .leading, spacing: 14) {
            if channel.hasOlder {
                Text("PULL FOR OLDER")
                    .text(.label(9.5))
                    .foregroundStyle(Theme.ink4)
                    .frame(maxWidth: .infinity)
            }
            ForEach(Array(staged.enumerated()), id: \.element.key) { _, row in
                row.view
                    .staged(.message(k: row.k), nav, mo)
            }
        }
        .padding(.horizontal, Theme.edge)
        .padding(.vertical, 18)
    }

    /// One flat list, indexed from the bottom so `k = 0` is the newest and
    /// arrives first. The staging table is written in those terms.
    private var staged: [Row] {
        var out: [Row] = []
        for moment in channel.moments {
            out.append(Row(key: "m\(moment.seq)", k: 0,
                           view: AnyView(MomentRow(moment: moment))))
        }
        for note in channel.notes {
            out.append(Row(key: "n\(note.seq)", k: 0,
                           view: AnyView(MomentRow(moment: note))))
        }
        if channel.continueOffer {
            out.append(Row(key: "continue", k: 0,
                           view: AnyView(ContinueRow(act: onContinue))))
        }
        for entry in channel.pending {
            out.append(Row(key: "p\(entry.id)", k: 0,
                           view: AnyView(PendingRow(entry: entry) { onRetry(entry.id) })))
        }
        let last = out.count - 1
        return out.enumerated().map { Row(key: $0.element.key, k: last - $0.offset,
                                          view: $0.element.view) }
    }

    private struct Row {
        let key: String
        let k: Int
        let view: AnyView
    }

    private var headerText: String {
        if channel.pagingOlder { return "LOADING OLDER" }
        if !channel.hasOlder { return "START OF WHAT ARCHSERVER KEPT" }
        return armed ? "RELEASE FOR OLDER" : "OLDER"
    }

    // MARK: - Scrolling

    private var minScroll: Double { min(0, viewport - content) }

    private func clampScroll(_ v: Double) -> Double { min(max(v, minScroll), 0) }

    private func band(_ v: Double) -> Double {
        if v > 0 { return rubber(v, max(viewport, 1), 0.62) }
        if v < minScroll { return minScroll - rubber(minScroll - v, max(viewport, 1), 0.62) }
        return v
    }

    private func unband(_ v: Double) -> Double {
        if v > 0 { return unrubber(v, max(viewport, 1), 0.62) }
        if v < minScroll { return minScroll - unrubber(minScroll - v, max(viewport, 1), 0.62) }
        return v
    }

    /// The thread grows at the bottom, and a chat that does not follow its own
    /// newest line is a chat you have to chase. It only follows when he was
    /// already there: scrolled up reading, new arrivals must not yank the view.
    private func grow(to height: Double, viewport height2: Double) {
        let wasAtBottom = scroll <= minScroll + 6 || content == 0
        content = height
        viewport = height2
        guard !dragging, wasAtBottom else { return }
        scroll = minScroll
    }

    private func arbiter(_ height: Double) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .local)
            .onChanged { value in
                // The left 44 pt belongs to the back gesture and nothing else.
                guard value.startLocation.x > Theme.backStrip else { return }
                if !dragging {
                    dragging = true
                    // Resume from the finger-space value, so grabbing a list
                    // that is still bouncing does not step under the thumb.
                    start = unband(scroll)
                }
                scroll = band(start + value.translation.height)
                armed = scroll > Self.pullThreshold
            }
            .onEnded { value in
                guard dragging else { return }
                dragging = false
                let vy = value.velocity.height
                let committed = armed
                armed = false
                if committed, channel.hasOlder, !channel.pagingOlder {
                    Task { await channel.older() }
                }
                if scroll > 0 || scroll < minScroll {
                    settle(to: clampScroll(scroll), velocity: vy * 0.25, spring: (120, 18))
                } else {
                    settle(to: clampScroll(scroll + project(vy)), velocity: vy, spring: (220, 30))
                }
            }
    }

    /// `initialVelocity` is normalised by the distance being animated, not an
    /// absolute rate: the raw finger velocity makes a short throw explode and a
    /// long throw feel dead.
    private func settle(to target: Double, velocity: Double, spring: (Double, Double)) {
        let distance = target - scroll
        let v0 = abs(distance) < 1e-4 ? 0 : velocity / distance
        withAnimation(.interpolatingSpring(mass: 1, stiffness: spring.0,
                                           damping: spring.1, initialVelocity: v0)) {
            scroll = target
        }
    }
}

// MARK: - One server moment

private struct MomentRow: View {
    let moment: Moment

    var body: some View {
        switch moment.kind {
        case .you: bubble
        case .claude: said
        case .tool: ToolRow(moment: moment)
        case .error: aside(Theme.sig)
        case .state, .summary: aside(Theme.ink3)
        }
    }

    private var bubble: some View {
        HStack {
            Spacer(minLength: 44)
            Text(moment.text)
                .text(.body)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius).fill(Theme.surf2))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var said: some View {
        Text(moment.text)
            .text(.body)
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func aside(_ tint: Color) -> some View {
        Text(moment.text)
            .text(.rowSubtitle)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tool call, with its duration bar -- **and only if `duration_ms` reached
/// the wire.** Without it the row renders with no bar, never a guessed one.
///
/// `viaSubagent` rows are dimmed and indented per SERVER-PLAN 2.
private struct ToolRow: View {
    let moment: Moment

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text((moment.tool ?? "tool").uppercased())
                .text(.label(9.5))
                .foregroundStyle(Theme.ink3)
            Text(moment.text)
                .text(.rowSubtitle)
                .foregroundStyle(Theme.ink2)
                .lineLimit(2)
            Spacer(minLength: 6)
            if let seconds = moment.duration {
                DurationBar(seconds: seconds)
            }
        }
        .padding(.leading, moment.viaSubagent ? 18 : 0)
        .opacity(moment.viaSubagent ? 0.62 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// `clamp(log10(1+s)/log10(61), 0, 1) * 44 + 3` pt, straight out of APP-PLAN
/// 5.3. Log, because a 40 ms `Read` and a 60 s `Bash` have to share one 44 pt
/// column and a linear scale renders every fast call as the same nothing.
private struct DurationBar: View {
    let seconds: TimeInterval

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Theme.ink4)
                .frame(width: width, height: 3)
            Text(label)
                .text(.label(9.5))
                .monospacedDigit()
                .foregroundStyle(Theme.ink3)
        }
        .accessibilityLabel("took \(label)")
    }

    private var width: Double {
        clamp(log10(1 + max(seconds, 0)) / log10(61), 0, 1) * 44 + 3
    }

    private var label: String {
        seconds < 1 ? "\(Int(seconds * 1000))ms"
                    : (seconds < 60 ? String(format: "%.1fs", seconds)
                                    : "\(Int(seconds / 60))m")
    }
}

// MARK: - The optimistic echo

/// **Never in `moments`.** A failed send flips to a retry affordance instead of
/// vanishing, which is the other half of bug 3: the old app left a bubble on
/// screen that had never been delivered.
private struct PendingRow: View {
    let entry: Channel.Pending
    let onRetry: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 44)
            VStack(alignment: .trailing, spacing: 6) {
                Text(entry.text)
                    .text(.body)
                    .foregroundStyle(entry.isFailed ? Theme.ink2 : Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                            .fill(Theme.surf2)
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.bubbleRadius)
                                    .stroke(entry.isFailed ? Theme.sig20 : .clear, lineWidth: 1))
                    )
                    .opacity(entry.isFailed ? 1 : 0.55)

                if case .failed(let why) = entry.delivery {
                    HStack(spacing: 10) {
                        Text(why)
                            .text(.label(9.5))
                            .foregroundStyle(Theme.sig)
                            .lineLimit(2)
                        Button(action: onRetry) {
                            Text("RETRY")
                                .text(.label(9.5))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Theme.line2))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.isFailed ? "not sent: \(entry.text)" : "sending: \(entry.text)")
    }
}

/// Compacted, but the server did not fire a continuation. Neither an error nor
/// a success -- so it offers the one thing that would finish the job.
private struct ContinueRow: View {
    let act: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("The session was compacted but not restarted.")
                .text(.rowSubtitle)
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 0)
            Button(action: act) {
                Text("CONTINUE")
                    .text(.label(9.5))
                    .foregroundStyle(Theme.bg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.surf))
        .accessibilityElement(children: .combine)
    }
}

private struct PullHeader: View {
    let text: String
    let armed: Bool

    var body: some View {
        Text(text)
            .text(.label(9.5))
            .foregroundStyle(armed ? Theme.ink : Theme.ink4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.settle, value: armed)
    }
}
