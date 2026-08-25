import SwiftUI

/// The agent list: absolutely placed rows over one scroll value.
///
/// **Why this is not a `ScrollView`.** Prime arbitrates row-drag against scroll
/// inside *one* recognizer with an 8 pt hysteresis and an axis lock. A per-row
/// `DragGesture` inside a `ScrollView` fights the scroll view over the
/// ambiguous first few points and the scroll view usually wins. Laying rows out
/// absolutely from the start is what makes that arbitration reachable in step 2
/// -- and it is also what lets the scene change read row positions directly in
/// step 3.
///
/// Step 0 places the rows and nothing else: no gesture, no momentum, no swipe.
struct FleetLayer: View {
    let fleet: Fleet
    let reachable: Reachability
    let refreshing: Bool
    let onSettings: () -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: Double = 88
    @ScaledMetric(relativeTo: .body) private var blockedRowHeight: Double = 116
    @ScaledMetric(relativeTo: .largeTitle) private var headerHeight: Double = 132

    @State private var scroll: Double = 0

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(
                order: fleet.order, fleet: fleet,
                viewport: geo.size.height, width: geo.size.width,
                headerHeight: headerHeight, rowHeight: rowHeight,
                blockedRowHeight: blockedRowHeight)

            ZStack(alignment: .topLeading) {
                Theme.bg

                FleetHeader(fleet: fleet, reachable: reachable, refreshing: refreshing)
                    .frame(height: headerHeight, alignment: .bottomLeading)
                    .offset(y: scroll)

                rows(metrics, width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: Space.list)
            .onTapGesture(coordinateSpace: .local) { point in
                if metrics.settingsHit(point, scroll: scroll) { onSettings() }
            }
        }
    }

    @ViewBuilder
    private func rows(_ m: Metrics, width: Double) -> some View {
        ForEach(m.visible(scroll: scroll), id: \.self) { i in
            let id = m.order[i]
            if let agent = fleet[id] {
                FleetRow(agent: agent, height: m.height(at: i))
                    .frame(width: width, height: m.height(at: i), alignment: .topLeading)
                    .offset(y: m.top(at: i) + scroll)
                    .zIndex(agent.isBlocked ? 1 : 0)
            }
        }
    }
}

// MARK: - Layout

/// Row tops, heights and bounds, recomputed per render from the roster.
///
/// A value type so it can be built in `body` and handed to every helper without
/// a second source of truth to keep in step -- a row's height depends on
/// whether it is blocked, and that changes underneath the scroll.
struct Metrics {
    let order: [AgentID]
    let viewport: Double
    let width: Double
    let headerHeight: Double
    let tops: [Double]
    let heights: [Double]
    let contentHeight: Double

    init(order: [AgentID], fleet: Fleet, viewport: Double, width: Double,
         headerHeight: Double, rowHeight: Double, blockedRowHeight: Double) {
        self.order = order
        self.viewport = viewport
        self.width = width
        self.headerHeight = headerHeight
        var tops: [Double] = []
        var heights: [Double] = []
        var y = headerHeight
        for id in order {
            let h = (fleet[id]?.isBlocked ?? false) ? blockedRowHeight : rowHeight
            tops.append(y)
            heights.append(h)
            y += h
        }
        self.tops = tops
        self.heights = heights
        // A run-out below the last row. Without it the last row sits against
        // the home indicator and cannot be swiped without the system gesture
        // taking the touch.
        self.contentHeight = y + 96
    }

    var minScroll: Double { min(0, viewport - contentHeight) }

    func height(at i: Int) -> Double { heights[i] }
    func top(at i: Int) -> Double { tops[i] }
    func index(of id: AgentID) -> Int? { order.firstIndex(of: id) }

    func clamp(_ v: Double) -> Double { min(max(v, minScroll), 0) }

    /// The 44 pt square the header's server glyph occupies, in viewport
    /// coordinates. It moves with the scroll because the header does.
    func settingsHit(_ point: CGPoint, scroll: Double) -> Bool {
        let top = headerHeight - 96 + scroll
        return point.x > width - 60 && point.y > top && point.y < top + 48
    }

    func row(atViewportY y: Double, scroll: Double) -> AgentID? {
        let contentY = y - scroll
        guard let i = tops.indices.first(where: {
            contentY >= tops[$0] && contentY < tops[$0] + heights[$0]
        }) else { return nil }
        return order[i]
    }

    /// Only what can be on screen, plus one row of margin either side. With
    /// four agents this is free; with four hundred it is the difference
    /// between a list and a slideshow.
    func visible(scroll: Double) -> [Int] {
        tops.indices.filter {
            let top = tops[$0] + scroll
            return top + heights[$0] > -heights[$0] && top < viewport + heights[$0]
        }
    }
}

// MARK: - Chrome

struct FleetHeader: View {
    let fleet: Fleet
    let reachable: Reachability
    let refreshing: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 8) {
                Text("HOTLINE")
                    .text(.wordmark)
                    .foregroundStyle(Theme.ink)
                Text(counts)
                    .text(.label(11))
                    .monospacedDigit()
                    .foregroundStyle(stale ? Theme.ink4 : Theme.ink3)
                    .animation(.enter, value: stale)
            }
            .padding(.horizontal, Theme.edge)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(counts)

            Image(systemName: "server.rack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink3)
                .frame(width: 44, height: 44)
                .padding(.top, 40)
                .padding(.trailing, Theme.edge - 12)
                .accessibilityLabel("Server address")
        }
    }

    private var stale: Bool {
        if case .stale = reachable { return true }
        return false
    }

    /// The age of the data is the honest readout when archserver is
    /// unreachable -- the counts are still true, they are just true about an
    /// older moment.
    private var counts: String {
        let total = fleet.agents.count
        let blocked = fleet.blockedCount
        var out = "\(total) AGENT\(total == 1 ? "" : "S")"
        if blocked > 0 { out += " · \(blocked) BLOCKED" }
        if refreshing {
            out += " · REFRESH"
        } else if case .stale(let since, _) = reachable {
            out += since.map { " · \(ago($0).uppercased()) OLD" } ?? " · NO CONTACT"
        }
        return out
    }
}
