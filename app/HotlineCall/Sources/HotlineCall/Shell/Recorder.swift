import SwiftUI

/// Telemetry's recorder strip (APP-PLAN 6.3): 342x104 above the timeline,
/// holding phase segments, the throughput waveform, the blocked span, tool
/// ticks and the playhead.
///
/// **The waveform's source, and its limit.** There is no throughput series on
/// the wire. The app builds one from the assistant-text events it holds --
/// characters between consecutive assistant events over the wall time between
/// their timestamps -- which is real, and coarse, and **stops where the fetched
/// history stops.** So the strip renders a run-in at its left edge saying
/// *older history not loaded* rather than drawing a line back to zero. Paging
/// more history in extends it leftward. Nothing is synthesised to fill it.
struct RecorderStrip: View {
    let route: Route
    let agent: Agent
    let session: ClosedRange<Date>?
    let samples: [Sample]
    /// Whether archserver has more history than this channel has fetched.
    let truncated: Bool
    @Binding var head: Playhead
    @Binding var budget: HapticBudget
    let onPurgeBefore: (Int) -> Void
    let seqAt: (TimeInterval) -> Int?

    @State private var startCursor: TimeInterval = 0
    @State private var dragging = false
    @State private var lastBoundary = -1
    @State private var menu = false

    private var span: TimeInterval {
        guard let session else { return 0 }
        return max(session.upperBound.timeIntervalSince(session.lowerBound), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            readouts
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 10).fill(Theme.surf)

                    if truncated {
                        // The honest left edge. It is a run-in, not a fade to
                        // zero, because zero would be a measurement.
                        HStack(spacing: 0) {
                            Rectangle()
                                .fill(Theme.ink5)
                                .frame(width: max(0, geo.size.width * 0.12))
                            Spacer(minLength: 0)
                        }
                        // **`rotationEffect` does not change layout.** It is a
                        // geometry effect: the layout system still sees the
                        // child's *unrotated* size. With `fixedSize()` after it
                        // the text took its natural ~132 pt width, was centred
                        // in a 60 pt-tall box, and painted ~36 pt past each end
                        // -- over the readouts above and the legend below.
                        //
                        // The frame that has to fit the string is therefore the
                        // one applied *before* the rotation, and its width is
                        // the height the label will occupy once turned. 96 pt
                        // is what this strip can spare; the scale factor takes
                        // up the rest rather than letting it spill again if the
                        // string or the type ramp ever changes.
                        Text("OLDER HISTORY NOT LOADED")
                            .text(.label(9.5))
                            .foregroundStyle(Theme.ink4)
                            .lineLimit(1)
                            .minimumScaleFactor(0.55)
                            .frame(width: 96)
                            .rotationEffect(.degrees(-90))
                            .frame(width: max(0, geo.size.width * 0.12), height: 96)
                            .clipped()
                            .padding(.top, 4)
                    }

                    phaseSegments(geo.size)
                    blockedSpan(geo.size)
                    Wave(points: wavePoints)
                        .stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.2,
                                                               lineCap: .round, lineJoin: .round))
                        .frame(height: 44)
                        .padding(.top, 18)
                    compactionRules(geo.size)
                    ticks(geo.size)
                    playhead(geo.size)
                }
                .contentShape(RoundedRectangle(cornerRadius: 10))
                .gesture(scrubGesture(width: geo.size.width))
                .onLongPressGesture(minimumDuration: 0.45) { menu = true }
            }
            .frame(height: 74)
            key
        }
        .sensoryFeedback(.selection, trigger: budget.pulse)
        .confirmationDialog("Route", isPresented: $menu, titleVisibility: .hidden) {
            // Scrubbing to a point and purging everything before it is the
            // natural use of a cursor, and `/agents/purge` takes `before_seq`.
            if let seq = seqAt(head.cursor) {
                Button("Delete everything before here", role: .destructive) {
                    onPurgeBefore(seq)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    // MARK: - Readouts

    /// `AT`, `OUTPUT`, `PHASE n of m` -- three cells, all sourced.
    ///
    /// **`CONTEXT at cursor` does not ship.** `Vitals` is a live snapshot and
    /// there is no context *series* behind it: the statusLine payload is not
    /// recorded per turn, so a value at an arbitrary past instant does not
    /// exist to be read.
    private var readouts: some View {
        HStack(alignment: .top, spacing: 22) {
            cell("AT", clockLabel)
            cell("OUTPUT", outputLabel)
            cell("PHASE", phaseLabel)
            Spacer(minLength: 0)
        }
    }

    private func cell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .text(.label(9.5))
                .foregroundStyle(Theme.ink3)
            Text(value)
                .text(.cellValue)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                .animation(.meter, value: value)
        }
    }

    private var clockLabel: String { hotlineClock(head.cursor) }

    /// The sample nearest the cursor, and nothing when there is no sample near
    /// it -- the series has holes wherever the agent was silent, and filling
    /// them in would be an interpolation dressed as a measurement.
    private var outputLabel: String {
        guard let session, let nearest = nearestSample(session) else { return "—" }
        return "\(Int(nearest.charsPerSec.rounded())) ch/s"
    }

    private var phaseLabel: String {
        guard let session, !route.phases.isEmpty else { return "—" }
        let instant = session.lowerBound.addingTimeInterval(head.cursor)
        guard let phase = route.phase(at: instant),
              let index = route.phases.firstIndex(where: { $0.id == phase.id }) else {
            return "— of \(route.phases.count)"
        }
        return "\(index + 1) of \(route.phases.count)"
    }

    private func nearestSample(_ session: ClosedRange<Date>) -> Sample? {
        let instant = session.lowerBound.addingTimeInterval(head.cursor)
        return samples.min { abs($0.at.timeIntervalSince(instant)) < abs($1.at.timeIntervalSince(instant)) }
            .flatMap { abs($0.at.timeIntervalSince(instant)) < span * 0.06 ? $0 : nil }
    }

    // MARK: - Marks

    private func x(_ instant: Date, _ width: Double) -> Double {
        guard let session else { return 0 }
        return clamp(instant.timeIntervalSince(session.lowerBound) / span, 0, 1) * width
    }

    private func phaseSegments(_ size: CGSize) -> some View {
        ForEach(Array(route.phases.enumerated()), id: \.element.id) { index, phase in
            let left = x(phase.startedAt, size.width)
            Rectangle()
                .fill(Theme.line)
                .frame(width: 1, height: size.height)
                .offset(x: left)
                .overlay(alignment: .topLeading) {
                    Text(String(format: "%02d", index + 1))
                        .text(.label(9.5))
                        .monospacedDigit()
                        .foregroundStyle(Theme.ink4)
                        .offset(x: left + 3, y: 2)
                }
        }
    }

    /// **Exact, and only for the span it can measure.**
    ///
    /// APP-PLAN 6.3 sources this from `conversations.waiting_since -> answered`.
    /// The daemon's `/conversations` holds `answered` as a boolean with no
    /// timestamp and keeps the whole set in memory, so a *past* blocked span has
    /// no source at all. The current one does: `blockedSince` on the roster. So
    /// the strip draws the block it can measure and draws no others, rather than
    /// inventing spans out of the fact that an answer exists.
    private func blockedSpan(_ size: CGSize) -> some View {
        Group {
            if agent.isBlocked, let since = agent.blockedAt {
                let left = x(since, size.width)
                ZStack(alignment: .bottomLeading) {
                    Rectangle().fill(Theme.sig12)
                    Rectangle().fill(Theme.sig).frame(height: 1)
                }
                .frame(width: max(2, size.width - left), height: size.height)
                .offset(x: left)
            }
        }
    }

    /// A compaction is the one place the context history *does* exist -- as two
    /// real points either side of a boundary -- so it gets a labelled rule.
    private func compactionRules(_ size: CGSize) -> some View {
        ForEach(route.compactions, id: \.seq) { moment in
            Rectangle()
                .fill(Theme.sigLift)
                .frame(width: 1, height: size.height)
                .offset(x: x(moment.at, size.width))
                .overlay(alignment: .bottomLeading) {
                    Text("COMPACT")
                        .text(.label(9.5))
                        .foregroundStyle(Theme.sigLift)
                        .offset(x: x(moment.at, size.width) + 3, y: -2)
                }
        }
    }

    private func ticks(_ size: CGSize) -> some View {
        let rows = route.phases.flatMap(\.tools) + route.unphased
        return ForEach(rows, id: \.seq) { moment in
            Rectangle()
                .fill(tickColour(toolTick(moment)))
                .frame(width: 1.5, height: 6)
                .offset(x: x(moment.at, size.width), y: size.height - 8)
        }
    }

    private func playhead(_ size: CGSize) -> some View {
        let left = clamp(head.cursor / span, 0, 1) * size.width
        return ZStack(alignment: .top) {
            Rectangle().fill(Theme.sig).frame(width: 1, height: size.height)
            Circle().fill(Theme.sig).frame(width: 7, height: 7).offset(y: -3)
        }
        .offset(x: left)
        .allowsHitTesting(false)
    }

    private var key: some View {
        HStack(spacing: 10) {
            ForEach(ToolTick.allCases, id: \.self) { kind in
                HStack(spacing: 4) {
                    Rectangle().fill(tickColour(kind)).frame(width: 6, height: 2)
                    Text(kind.key.uppercased())
                        .text(.label(9.5))
                        .foregroundStyle(Theme.ink4)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    // MARK: - The scrub

    /// 1:1 with the finger across the strip's own width, rubber-banded past the
    /// ends, with a `.selection` pulse at each boundary crossed.
    private func scrubGesture(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    startCursor = head.cursor
                }
                let t = startCursor / span + value.translation.width / max(width, 1)
                head.scrub(to: banded(t) * span)
                crossed()
            }
            .onEnded { value in
                dragging = false
                let landing = (head.cursor / span + project(value.velocity.width) / max(width, 1))
                let target = clamp(landing, 0, 1) * span
                let boundaries = route.boundaries(since: session?.lowerBound ?? .now)
                // Momentum on release, and the snap rides it rather than
                // teleporting: the playhead's x is linear in the cursor, so the
                // interpolated offset is the same number re-derived.
                withAnimation(.snap) {
                    if let snap = snapped(target, to: boundaries, span: span) {
                        head.scrub(to: snap)
                        budget.fire()
                    } else {
                        head.scrub(to: target)
                    }
                }
                head.release()
            }
    }

    private func banded(_ t: Double) -> Double {
        if t > 1 { return 1 + rubber(t - 1, 1, 0.62) }
        if t < 0 { return -rubber(-t, 1, 0.62) }
        return t
    }

    private func crossed() {
        let bounds = route.boundaries(since: session?.lowerBound ?? .now)
        let index = bounds.lastIndex { $0 <= head.cursor } ?? -1
        guard index != lastBoundary else { return }
        lastBoundary = index
        budget.fire()
    }

    private var wavePoints: [CGPoint] {
        guard let session, samples.count > 1 else { return [] }
        let ceiling = max(samples.map(\.charsPerSec).max() ?? 1, 1)
        return samples.map {
            CGPoint(x: clamp($0.at.timeIntervalSince(session.lowerBound) / span, 0, 1),
                    y: 1 - clamp($0.charsPerSec / ceiling, 0, 1))
        }
    }

    private var spoken: String {
        var parts = ["recorder", "at \(clockLabel)", "phase \(phaseLabel)"]
        if agent.isBlocked { parts.append("blocked") }
        if truncated { parts.append("older history not loaded") }
        return parts.joined(separator: ", ")
    }
}

/// The waveform. One `Shape`, holding nothing but values -- `path(in:)` runs off
/// the main actor, which is what makes it structurally impossible to hand this
/// a `Channel`.
nonisolated struct Wave: Shape {
    var points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1 else { return path }
        for (index, point) in points.enumerated() {
            let at = CGPoint(x: rect.minX + point.x * rect.width,
                             y: rect.minY + point.y * rect.height)
            if index == 0 { path.move(to: at) } else { path.addLine(to: at) }
        }
        return path
    }
}
