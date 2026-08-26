import SwiftUI

/// The route, pulled down over a channel like a blind (APP-PLAN 6).
///
/// One layer merging Prime's phase timeline with Telemetry's recorder strip. It
/// is pushed into from a channel rather than being a tab, which is how
/// `DESIGN.md`'s contradiction was resolved: he described a per-agent map in
/// detail and then selected only `Chat` when asked which tabs he wanted.
///
/// **Where the phases come from is not where the plan said they would be.**
/// APP-PLAN 6.2 reads them off `/agents/history`'s phase records; the deployed
/// daemon sends no such key, and SERVER-PLAN §6's own response column for that
/// endpoint does not list one either. They are reconstructed from the event
/// stream instead -- see `Store/Route.swift`, where the reconstruction is
/// Foundation-only and therefore actually executed by `app/wiretest/run.sh`.
struct MapLayer: View {
    let agent: Agent
    let channel: Channel
    /// 0...1, the same mechanism as `nav`: scrubbable, reversible, drag-owned.
    let progress: Double
    let mo: Double
    let onDrag: (SheetPhase) -> Void
    let onPurgeBefore: (Int) -> Void

    /// The timeline's scroll, and the strip's cursor, as one value seen twice.
    @State private var head = Playhead()
    @State private var scroll: Double = 0
    @State private var scrollStart: Double = 0
    @State private var dragging = false
    @State private var reveal: Double = 0
    @State private var budget = HapticBudget()

    /// The focus band sits 170 pt from the top of the map view. The content has
    /// a 170 pt lead-in and a 380 pt run-out: without them the timeline can
    /// never bring its own ends into the band, **and the last phase is exactly
    /// where a blocked agent lives.**
    private static let band: Double = 170
    private static let leadIn: Double = 170
    private static let runOut: Double = 380
    private static let phaseRow: Double = 84
    private static let toolRow: Double = 27

    private var route: Route { channel.route }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                grabber
                RecorderStrip(route: route, agent: agent, session: session,
                              samples: rebuiltSamples(from: channel.moments),
                              truncated: channel.hasOlder,
                              head: $head, budget: $budget,
                              onPurgeBefore: { onPurgeBefore($0) },
                              seqAt: seq(at:))
                    .frame(height: 104)
                    .padding(.horizontal, Theme.edge)
                    .padding(.bottom, 14)
                timeline(geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            .background(Theme.bgLift.ignoresSafeArea())
            .offset(y: -(1 - progress) * geo.size.height)
            .gesture(blind(height: geo.size.height))
        }
        .allowsHitTesting(progress > 0.5)
        // The reveal is torn down 440 ms *after* the panel has left, not on
        // release: resetting on release empties the map while he is still
        // watching it go.
        .onChange(of: progress > 0.04) { _, peeking in
            if peeking {
                withAnimation(.enter.delay(0.09)) { reveal = 1 }
            } else {
                Task {
                    try? await Task.sleep(for: .milliseconds(440))
                    if progress <= 0.04 { reveal = 0 }
                }
            }
        }
    }

    private var grabber: some View {
        VStack(spacing: 10) {
            Capsule()
                .fill(Theme.line2)
                .frame(width: 38, height: 4)
                .padding(.top, 12)
            HStack(spacing: 10) {
                Text("ROUTE")
                    .text(.label(10))
                    .foregroundStyle(Theme.ink3)
                Text(agent.name)
                    .text(.rowName)
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.edge)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)
        .contentShape(Rectangle())
    }

    // MARK: - The timeline

    private func timeline(_ size: CGSize) -> some View {
        // The spine draws down and the phases follow it as the panel arrives.
        let spine = clamp(reveal * 1.15, 0, 1)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.line2)
                .frame(width: 1)
                .frame(maxHeight: .infinity, alignment: .top)
                .scaleEffect(y: spine, anchor: .top)
                .padding(.leading, Theme.edge + 5)
                .allowsHitTesting(false)

            let tops = column
            ForEach(Array(route.phases.enumerated()), id: \.element.id) { index, phase in
                let top = tops[index] + scroll
                PhaseRow(phase: phase, index: index, count: route.phases.count,
                         on: focusBand(top: top, band: Self.band),
                         appear: smoothstep(clamp((reveal - Double(index) * 0.10) / 0.5, 0, 1)),
                         mo: mo)
                    .frame(width: size.width - Theme.edge * 2, alignment: .leading)
                    .offset(x: Theme.edge, y: top)
            }

            MapFoot(open: route.phases.last?.isOpen ?? false,
                    blocked: agent.isBlocked,
                    unphased: route.unphased.count,
                    empty: route.isEmpty)
                .frame(width: size.width - Theme.edge * 2, alignment: .leading)
                .offset(x: Theme.edge, y: (tops.last ?? Self.leadIn) + scroll)
                .opacity(reveal)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipped()
        .contentShape(Rectangle())
        .gesture(scrub(height: size.height))
        .accessibilityScrollAction { edge in
            settle(to: clampScroll(scroll + (edge == .top ? 240 : -240)), velocity: 0)
        }
        .onChange(of: head.cursor) { _, cursor in follow(cursor) }
    }

    /// Every phase's top, computed once, top-down.
    ///
    /// A phase's height depends on how open it is, and how open it is depends on
    /// where its top has landed -- so the two are genuinely mutually recursive.
    /// Written as two functions calling each other it is **exponential**, not
    /// quadratic: `rowTop(n)` asks `openHeight(n-1)` which asks `rowTop(n-1)`
    /// and so on, and twenty phases is a million calls per frame. Walking the
    /// column once, downward, is the same arithmetic in O(n) because each top
    /// only ever depends on the ones above it.
    ///
    /// **The height is written only when the rounded value changes.** Height is
    /// the one non-compositor property on this screen -- there is no transform
    /// equivalent for a list closing a gap -- so it is not written per frame.
    private var column: [Double] {
        var tops: [Double] = []
        var y = Self.leadIn
        for phase in route.phases {
            tops.append(y)
            let on = focusBand(top: y + scroll, band: Self.band)
            y += Self.phaseRow + (on * Double(phase.tools.count) * Self.toolRow + 2).rounded()
        }
        tops.append(y)
        return tops
    }

    private var contentHeight: Double {
        (column.last ?? Self.leadIn) + Self.runOut
    }

    // MARK: - Scrubbing the timeline

    private func clampScroll(_ v: Double) -> Double {
        min(max(v, min(0, 600 - contentHeight)), 0)
    }

    private func scrub(height: Double) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    scrollStart = scroll
                    head.follow(cursor(forScroll: scroll))
                }
                scroll = clampScroll(scrollStart + value.translation.height)
                head.follow(cursor(forScroll: scroll))
            }
            .onEnded { value in
                dragging = false
                // Release snaps to the phase nearest the projected end.
                let landing = clampScroll(scroll + project(value.velocity.height))
                let nearest = nearestPhase(to: landing)
                head.release()
                settle(to: nearest ?? landing, velocity: value.velocity.height)
            }
    }

    private func nearestPhase(to landing: Double) -> Double? {
        guard !route.phases.isEmpty else { return nil }
        let tops = column
        var best: Double?
        var gap = Double.greatestFiniteMagnitude
        for index in route.phases.indices {
            let target = Self.band - tops[index]
            let distance = abs(target - landing)
            if distance < gap { gap = distance; best = target }
        }
        return best.map { clampScroll($0) }
    }

    private func settle(to target: Double, velocity: Double) {
        let distance = target - scroll
        let v0 = abs(distance) < 1e-4 ? 0 : velocity / distance
        withAnimation(.interpolatingSpring(mass: 1, stiffness: 380, damping: 32,
                                           initialVelocity: v0)) {
            scroll = target
        }
    }

    // MARK: - One cursor, seen twice

    private var session: ClosedRange<Date>? {
        guard let first = channel.moments.first?.at else { return nil }
        let last = max(channel.moments.last?.at ?? first, first.addingTimeInterval(1))
        return first...last
    }

    /// The instant the focus band is sitting on, in seconds from the session's
    /// start. This is the timeline writing the shared cursor.
    private func cursor(forScroll value: Double) -> TimeInterval {
        guard let session else { return 0 }
        let y = Self.band - value
        let tops = column
        var index = 0
        for i in route.phases.indices where tops[i] <= y { index = i }
        guard route.phases.indices.contains(index) else { return 0 }
        return route.phases[index].startedAt.timeIntervalSince(session.lowerBound)
    }

    /// And this is the strip writing it. The `Driver` enum is what stops the
    /// two from oscillating: whichever surface is under a finger owns the
    /// cursor and the other one's write is refused until the gesture ends.
    private func follow(_ cursor: TimeInterval) {
        // `!= .timeline` rather than `== .strip`: the strip releases the driver
        // in the same gesture callback that writes the snapped cursor, so by
        // the time this observer runs the driver is already `.neither` and a
        // guard on `.strip` would drop exactly the write that matters.
        guard head.driver != .timeline, let session else { return }
        let instant = session.lowerBound.addingTimeInterval(cursor)
        guard let phase = route.phase(at: instant),
              let index = route.phases.firstIndex(where: { $0.id == phase.id }) else { return }
        withAnimation(.glide) { scroll = clampScroll(Self.band - column[index]) }
    }

    /// The `seq` the cursor resolves to, for "delete everything before here".
    private func seq(at cursor: TimeInterval) -> Int? {
        guard let session else { return nil }
        let instant = session.lowerBound.addingTimeInterval(cursor)
        return channel.moments.last { $0.at <= instant }?.seq
    }

    // MARK: - The blind

    private func blind(height: Double) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard value.startLocation.y < 90 else { return }
                onDrag(.move(clamp(progress + value.translation.height / max(height, 1) * 1.35, 0, 1)))
            }
            .onEnded { value in
                guard value.startLocation.y < 90 else { return }
                onDrag(.release(value.velocity.height / max(height, 1) * 1.35))
            }
    }

    private func smoothstep(_ t: Double) -> Double { t * t * (3 - 2 * t) }
}

// MARK: - One phase

/// A phase, and its tool calls when it is the one in the focus band.
private struct PhaseRow: View {
    let phase: RoutePhase
    let index: Int
    let count: Int
    let on: Double
    let appear: Double
    let mo: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(phase.isOpen ? Theme.sig : Theme.ink3)
                        .frame(width: 9, height: 9)
                }
                .frame(width: 11)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(String(format: "%02d", index + 1))
                            .text(.label(9.5))
                            .monospacedDigit()
                            .foregroundStyle(Theme.ink4)
                        if let span = phase.duration {
                            Text(durationLabel(span))
                                .text(.label(9.5))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink3)
                        }
                        Spacer(minLength: 0)
                        if phase.tools.count > 0 {
                            Text("\(phase.tools.count)")
                                .text(.label(9.5))
                                .monospacedDigit()
                                .foregroundStyle(Theme.ink4)
                        }
                    }
                    // **A leg whose opening event is not in the loaded history
                    // has no title, and says so.** Naming it anything would be
                    // the fabricated readout this project has refused once.
                    Text(phase.title ?? "title not in the loaded history")
                        .text(.rowName)
                        .foregroundStyle(phase.title == nil ? Theme.ink3 : Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let outcome = phase.outcome {
                        Text(outcome)
                            .text(.rowSubtitle)
                            .foregroundStyle(Theme.ink2)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
            }
            .opacity(0.42 + 0.58 * on)

            // Tools stagger open outward from the first.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(phase.tools.enumerated()), id: \.element.seq) { k, tool in
                    let q = toolStagger(on, k)
                    ToolTickRow(moment: tool)
                        .frame(height: 27)
                        .opacity(q)
                        .offset(x: (1 - q) * -12 * mo)
                }
            }
            .frame(height: (on * Double(phase.tools.count) * 27 + 2).rounded(), alignment: .top)
            .clipped()
            .padding(.leading, 23)
        }
        .opacity(appear)
        .offset(y: (1 - appear) * 14 * mo)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spoken)
    }

    private var spoken: String {
        var parts = ["phase \(index + 1) of \(count)"]
        parts.append(phase.title ?? "title not loaded")
        if let outcome = phase.outcome { parts.append(outcome) }
        if phase.isOpen { parts.append("still running") }
        parts.append("\(phase.tools.count) tool calls")
        return parts.joined(separator: ", ")
    }
}

private struct ToolTickRow: View {
    let moment: Moment

    var body: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(tickColour(toolTick(moment)))
                .frame(width: 3, height: 12)
            Text((moment.tool ?? "tool").uppercased())
                .text(.label(9.5))
                .foregroundStyle(Theme.ink3)
            Text(moment.text)
                .text(.rowSubtitle)
                .foregroundStyle(moment.kind == .compact ? Theme.sigLift : Theme.ink2)
                .lineLimit(1)
            Spacer(minLength: 6)
            // Only when the server measured it. A row without `duration_ms`
            // gets no bar rather than a guessed one.
            if let seconds = moment.duration {
                Capsule()
                    .fill(Theme.ink4)
                    .frame(width: durationBarWidth(seconds), height: 3)
            }
        }
        // Subagent rows are dimmed and indented, per SERVER-PLAN §2.
        .padding(.leading, moment.viaSubagent ? 14 : 0)
        .opacity(moment.viaSubagent ? 0.62 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// APP-PLAN 6.3's five buckets. The fifth exists because a four-way
/// classification of an open-ended tool namespace silently mislabels every MCP
/// tool, and a bucket that admits it does not know is the honest version.
nonisolated func tickColour(_ tick: ToolTick) -> Color {
    switch tick {
    case .read: Theme.ink3
    case .edit: Theme.ink.opacity(0.58)
    case .shell: Theme.ink.opacity(0.92)
    case .signal: Theme.sig
    case .other: Theme.ink.opacity(0.44)
    }
}

/// **Empty screen that is actually the future must be named, or it reads as a
/// rendering bug.**
private struct MapFoot: View {
    let open: Bool
    let blocked: Bool
    let unphased: Int
    let empty: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headline)
                .text(.label(10))
                .foregroundStyle(Theme.ink3)
            if unphased > 0 {
                // Named rather than filed into a phantom phase, which is the
                // same rule SERVER-PLAN §2 applies on its own side.
                Text("\(unphased) tool call\(unphased == 1 ? "" : "s") archserver could not attribute to a phase")
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink4)
            }
        }
        .padding(.leading, 23)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var headline: String {
        if empty { return "NO ROUTE ON THIS CHANNEL YET" }
        if blocked { return "ROUTE CONTINUES WHEN YOU ANSWER" }
        return open ? "STILL RUNNING" : "END OF ROUTE"
    }
}
