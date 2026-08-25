import SwiftUI

/// APP-PLAN 5.3, and **it lives inside a channel and nowhere else.**
///
/// Bogdan scoped Telemetry's readouts to the inside of the agent chat on
/// 2026-08-26 (APP-PLAN 5.0). The fleet row carries none of this and the
/// boundary is checkable: nothing in `FleetRow.swift` reads `Vitals`.
///
/// Every cell here renders **only if it has a source**. A strip of dashes is a
/// readout claiming to be a measurement, so an absent `Vitals` renders no cell
/// at all rather than a placeholder -- which is why the strip's own layout has
/// to look finished at three cells as well as at four.
struct InstrumentStrip: View {
    let agent: Agent
    let channel: Channel
    let nav: Double
    let mo: Double

    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var sparkHeight: Double = 30

    /// The window the sparkline is showing, in seconds. Held per channel for
    /// the session: released, it stays where it was put.
    @State private var span: TimeInterval = 90

    /// **Dropped, not clipped**, at accessibility sizes: a 30 pt sparkline
    /// under 34 pt text is noise. Every number survives; the graph does not.
    private var compact: Bool { typeSize >= .accessibility1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compact { grid } else { row }

            if !compact, !channel.samples.isEmpty {
                SparklineMark(ring: channel.samples, span: $span, height: sparkHeight)
                    .staged(.stripCell(cells.count), nav, mo)
            }

            contextBar
        }
    }

    // MARK: - The cells

    private var row: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                CellView(cell: cell)
                    .staged(.stripCell(index), nav, mo)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    /// The reflow, not a shrink: at accessibility sizes the cells stack two
    /// wide and the numbers stay full size.
    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)],
                  alignment: .leading, spacing: 14) {
            ForEach(cells) { CellView(cell: $0) }
        }
        .accessibilityElement(children: .combine)
    }

    private struct Cell: Identifiable {
        let id: String
        let label: String
        var value: String?
        /// A live clock, ticked locally rather than at the roster's cadence.
        var clockFrom: Date?
        var hot = false
    }

    private var cells: [Cell] {
        var out: [Cell] = []
        if let vitals = agent.vitals {
            // Characters, not a tokenizer count, and never a billing figure.
            // SERVER-PLAN 9.2 is explicit; the prototype said `tok/s` because
            // it was drawing an invented number.
            out.append(Cell(id: "output", label: "OUTPUT",
                            value: "\(Int(vitals.tokensPerSec.rounded())) ch/s"))
            if let context = contextCell { out.append(context) }
            out.append(Cell(id: "tools", label: "TOOLS",
                            value: String(format: "%.1f /min", vitals.toolsPerMin)))
        }

        // The label swaps with the state, and both tick every second. This is
        // the one readout on the strip whose source is a timestamp rather than
        // a sample, so it must not sit still between roster wakes.
        if agent.isBlocked, let since = agent.blockedAt {
            out.append(Cell(id: "blocked", label: "BLOCKED", clockFrom: since, hot: true))
        } else if agent.isBlocked, let seconds = agent.vitals?.blockedFor {
            // No timestamp on the wire, only the server's own measurement. It
            // is true and it does not tick; saying it once beats inventing a
            // clock to make it move.
            out.append(Cell(id: "blocked", label: "BLOCKED", value: hotlineClock(seconds), hot: true))
        } else if let declared = agent.declaredDate {
            out.append(Cell(id: "elapsed", label: "ELAPSED", clockFrom: declared))
        }
        return out
    }

    /// APP-PLAN 5.6's three states, and only one of them is a number.
    ///
    /// The distinction is why the plan asked for one boolean: an empty track
    /// that is going to fill in thirty seconds and one that will never fill
    /// look identical and mean opposite things.
    private var contextCell: Cell? {
        if let used = agent.vitals?.contextUsed {
            return Cell(id: "context", label: "CONTEXT",
                        value: "\(Int((used * 100).rounded())) %", hot: used > 0.85)
        }
        // "Not yet": the session has not taken its first turn, so the CLI
        // reports null and a real number is coming. Requires the server to
        // have *said* so -- an absent `contextAvailable` cannot distinguish
        // this from "never", and rendering a dash forever would be exactly the
        // fabricated readout this project has already refused once.
        if agent.contextAvailable == true {
            return Cell(id: "context", label: "CONTEXT", value: "—")
        }
        // "Unavailable": no statusLine wrapper for that session. The cell is
        // not rendered at all and the strip lays out with three cells, evenly,
        // and looks finished. Settings says it once, in words.
        return nil
    }

    private struct CellView: View {
        let cell: Cell

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                Text(cell.label)
                    .text(.label(9.5))
                    .foregroundStyle(Theme.ink3)
                if let from = cell.clockFrom {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        value(hotlineClock(max(0, context.date.timeIntervalSince(from))))
                    }
                } else if let text = cell.value {
                    value(text)
                }
            }
        }

        private func value(_ text: String) -> some View {
            Text(text)
                .text(.cellValue)
                .monospacedDigit()
                .foregroundStyle(cell.hot ? Theme.sig : Theme.ink)
                // Per glyph, so a changing number does not blur-crossfade the
                // digits that did not change.
                .contentTransition(.numericText())
                .animation(.meter, value: text)
        }
    }

    // MARK: - The context bar

    /// The same three states as the cell, one layer down.
    ///
    /// **Unavailable renders no bar at all, not an empty one.** An empty track
    /// means "waiting for the first sample"; absence means "this session will
    /// never report it".
    @ViewBuilder
    private var contextBar: some View {
        if agent.vitals != nil, agent.contextAvailable != false {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink5)
                    if let used = agent.vitals?.contextUsed {
                        Capsule()
                            .fill(used > 0.85 ? Theme.sig : Theme.ink2)
                            .frame(width: max(0, geo.size.width * clamp(used, 0, 1)))
                    }
                }
            }
            .frame(height: 2)
            // A readout that jumps reads as a refresh; a readout that moves
            // reads as a measurement. This is the animation the compact button
            // pays off: the bar falls to a value the server measured, five
            // seconds later, and the app never computes it from `postTokens`.
            .animation(.meter, value: agent.vitals?.contextUsed)
            .accessibilityHidden(true)
        }
    }

}

/// Tabular, and it does not round up into a lie.
nonisolated func hotlineClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

// MARK: - The sparkline and its window

/// 342x30 visually, 342x44 to the finger, so the drag does not compete with the
/// thread's scroll below it.
private struct SparklineMark: View {
    let ring: SampleRing
    @Binding var span: TimeInterval
    let height: Double

    @State private var startSpan: TimeInterval = 90
    @State private var dragging = false
    @State private var budget = HapticBudget()
    @State private var lastDetent = 0

    /// The full retention of the ring: 90 s to 30 min, on a log scale, so the
    /// finger travels the same distance per doubling anywhere in the range.
    private static let narrow: TimeInterval = 90
    private static let wide: TimeInterval = 1800
    private static let detents: [TimeInterval] = [90, 300, 1800]

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                Text(spanLabel)
                    .text(.label(9.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink3)
                Sparkline(points: points)
                    .stroke(Theme.ink2, style: StrokeStyle(lineWidth: 1.5,
                                                           lineCap: .round, lineJoin: .round))
                    .frame(height: height)
            }
            .frame(width: geo.size.width, alignment: .leading)
            // The visual is 30; the hit area is 44.
            .frame(height: 44 + 14, alignment: .top)
            .contentShape(Rectangle())
            .gesture(scrub(width: geo.size.width))
            .sensoryFeedback(.selection, trigger: budget.pulse)
            // The content is the OUTPUT cell; the mark is a second view of it.
            .accessibilityHidden(true)
        }
        .frame(height: 44 + 14)
    }

    /// Decimated on the main actor and handed over as values. A mark can never
    /// be given a `Channel`: `Shape.path(in:)` runs off the main actor, which
    /// is why `Sample` and `SampleRing` are value types in the first place.
    private var points: [CGPoint] {
        let window = ring.window(span)
        guard window.count > 1, let first = window.first, let last = window.last else { return [] }
        let width = max(last.at.timeIntervalSince(first.at), 1)
        let ceiling = max(window.map(\.charsPerSec).max() ?? 1, 1)
        // Plotted against **real timestamps**, not sample index, and not
        // smoothed: a network stall reads as a long flat run rather than being
        // interpolated into a plausible curve.
        return window.map {
            CGPoint(x: $0.at.timeIntervalSince(first.at) / width,
                    y: 1 - clamp($0.charsPerSec / ceiling, 0, 1))
        }
    }

    private var spanLabel: String {
        span < 120 ? "\(Int(span)) S"
                   : (span < 3600 ? String(format: "%.1f MIN", span / 60).replacingOccurrences(of: ".0", with: "")
                                  : "\(Int(span / 3600)) H")
    }

    private func scrub(width: Double) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    startSpan = span
                }
                // 1:1 against the log scale. Left narrows, right widens.
                let t0 = position(of: startSpan)
                let t = t0 + value.translation.width / max(width, 1)
                span = size(at: banded(t))
                crossed()
            }
            .onEnded { _ in
                dragging = false
                withAnimation(.settle) { span = clamp(span, Self.narrow, Self.wide) }
            }
    }

    /// Rubber-banded at both ends, in the log parameter rather than in seconds,
    /// so the resistance feels the same at 90 s as at 30 min.
    private func banded(_ t: Double) -> Double {
        if t > 1 { return 1 + rubber(t - 1, 1, 0.62) }
        if t < 0 { return -rubber(-t, 1, 0.62) }
        return t
    }

    private func position(of seconds: TimeInterval) -> Double {
        log(seconds / Self.narrow) / log(Self.wide / Self.narrow)
    }

    private func size(at t: Double) -> TimeInterval {
        Self.narrow * pow(Self.wide / Self.narrow, t)
    }

    private func crossed() {
        let index = Self.detents.lastIndex { span >= $0 - 1 } ?? 0
        guard index != lastDetent else { return }
        var copy = budget
        copy.fire()
        budget = copy
        lastDetent = index
    }
}

/// One mark, one `Shape`, holding nothing but values.
///
/// `nonisolated` is not decoration: SwiftUI calls `path(in:)` off the main
/// actor. That is also what makes it structurally impossible to hand this a
/// `Channel` -- the type simply cannot store one.
nonisolated struct Sparkline: Shape {
    /// Unit space: x is position in the window, y is 0 at the top.
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

// MARK: - The tool dot

/// One flash per real `tool` event on the feed: opacity 0.30 -> 1 and scale
/// 1 -> 1.5 over 70 ms in, 400 ms out.
///
/// **The feed carries every tool call, so this is exact.** It is the readout
/// that could not be honest on a list row -- where the roster only samples
/// every few seconds and calls would be missed -- and is honest here.
struct ToolDot: View {
    let flashes: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var level: Double = 0.30

    var body: some View {
        Circle()
            .fill(Theme.ink)
            .frame(width: 5, height: 5)
            .opacity(level)
            .scaleEffect(1 + (level - 0.30) * (0.5 / 0.7))
            .onChange(of: flashes) { _, _ in flash() }
            .accessibilityHidden(true)
    }

    private func flash() {
        guard !reduceMotion else { return }
        withAnimation(.easeOut(duration: 0.07)) { level = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(70))
            withAnimation(.easeOut(duration: 0.4)) { level = 0.30 }
        }
    }
}
