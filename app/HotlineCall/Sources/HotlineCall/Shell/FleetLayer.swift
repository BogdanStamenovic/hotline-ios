import SwiftUI

/// The agent list: absolutely placed rows over one scroll value, with a single
/// gesture recognizer arbitrating row-drag against scroll.
///
/// **Why this is not a `ScrollView`.** Prime arbitrates row-drag against scroll
/// inside *one* recognizer with an 8 pt hysteresis and an axis lock. A per-row
/// `DragGesture` inside a `ScrollView` fights the scroll view over the
/// ambiguous first few points and the scroll view usually wins. Building the
/// surface buys, and nothing else reaches: that arbitration, pull past the
/// bottom to brief, pull past the top with its own meaning, rows whose order
/// and height animate independently of the scroll, and the scene change reading
/// row positions directly.
///
/// What it costs, stated once so nobody rediscovers it: rubber-banding,
/// momentum and keyboard avoidance are ours, and `ScrollView`'s free
/// accessibility scrolling is gone -- which is why `accessibilityScrollAction`
/// below is not optional.
struct FleetLayer: View {
    let fleet: Fleet
    let nav: Double
    let hero: AgentID?
    let mo: Double
    let reachable: Reachability
    let refreshing: Bool
    @Binding var titleFrames: [AgentID: CGRect]
    let onOpen: (AgentID) -> Void
    let onRefresh: () -> Void
    let onBrief: () -> Void
    let onControl: (Agent, Capability) -> Void
    let onSettings: () -> Void

    @ScaledMetric(relativeTo: .body) private var rowHeight: Double = 88
    @ScaledMetric(relativeTo: .body) private var blockedRowHeight: Double = 116
    @ScaledMetric(relativeTo: .largeTitle) private var headerHeight: Double = 132

    @State private var scroll: Double = 0
    /// Where the scroll was when the current settle started. `scroll` is the
    /// *model* value, which `withAnimation` sets to its target immediately, so
    /// virtualising against it alone would unmount every row the fling is
    /// travelling past while it is still travelling past them.
    @State private var scrollAnchor: Double = 0
    @State private var drag = DragArbiter()
    /// The one row currently pulled aside. Only one, ever: a second open row is
    /// a state nobody can act on and every list that allows it feels broken.
    @State private var swiped: AgentID?
    @State private var swipeX: Double = 0
    @State private var pullChip: PullChip = .none

    /// The distance a pull past an edge must project to before it means
    /// something. Both edges share it so the two gestures feel like one
    /// mechanism with two meanings.
    private static let pullThreshold: Double = 74

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(
                order: fleet.order, fleet: fleet,
                viewport: geo.size.height, width: geo.size.width,
                headerHeight: headerHeight, rowHeight: rowHeight,
                blockedRowHeight: blockedRowHeight)

            ZStack(alignment: .topLeading) {
                Theme.bg

                pullAffordance(metrics)

                FleetHeader(fleet: fleet, reachable: reachable,
                            refreshing: refreshing, chip: pullChip)
                    .frame(height: headerHeight, alignment: .bottomLeading)
                    .offset(y: scroll)

                rows(metrics, width: geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: Space.list)
            .gesture(arbiter(metrics))
            .accessibilityScrollAction { edge in
                let page = metrics.viewport * 0.8
                settle(to: metrics.clamp(scroll + (edge == .top ? page : -page)),
                       velocity: 0, spring: (520, 46))
            }
            .onChange(of: metrics.minScroll) { _, low in
                // The roster shrank under us -- a purge, a retire, an agent
                // that finished. Bring the surface back into bounds rather than
                // leaving it parked over empty space.
                if scroll < low { settle(to: low, velocity: 0, spring: (220, 30)) }
            }
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func rows(_ m: Metrics, width: Double) -> some View {
        let heroIndex = hero.flatMap { m.index(of: $0) }
        // Keyed by agent, never by index. Index identity would recycle a row
        // view onto a different agent when the roster reorders -- which is
        // exactly what a blocked agent climbing the list does -- taking that
        // row's animation state with it.
        ForEach(m.visible(from: scrollAnchor, to: scroll), id: \.self) { id in
            if let i = m.index(of: id), let agent = fleet[id] {
                FleetRow(
                    agent: agent,
                    height: m.height(at: i),
                    isHero: hero == id,
                    swipeX: swiped == id ? swipeX : 0,
                    nav: nav, mo: mo,
                    titleFrame: $titleFrames,
                    onControl: { onControl(agent, $0) })
                .frame(width: width, height: m.height(at: i), alignment: .topLeading)
                .staged(role(for: i, heroIndex: heroIndex), nav, mo)
                .offset(y: m.top(at: i) + scroll)
                .zIndex(agent.isBlocked ? 1 : 0)
            }
        }
    }

    private func role(for i: Int, heroIndex: Int?) -> Role {
        guard let heroIndex else { return .row(d: 0) }
        return i == heroIndex ? .heroRow : .row(d: i - heroIndex)
    }

    // MARK: - The pull affordances
    //
    // One meaning per gesture per surface (APP-PLAN 4.7): past the top is a
    // hard refresh, past the bottom briefs a new agent. Both live in the gap
    // the overscroll opens, so neither is chrome that occupies space when it is
    // not being asked for.

    @ViewBuilder
    private func pullAffordance(_ m: Metrics) -> some View {
        if max(scroll, scrollAnchor) > 4 {
            PullLabel(text: pullChip == .refresh ? "RELEASE TO REFRESH" : "REFRESH",
                      armed: pullChip == .refresh)
                .frame(height: max(scroll, 0), alignment: .center)
                .frame(maxWidth: .infinity)
        }
        if min(scroll, scrollAnchor) < m.minScroll - 4 {
            PullLabel(text: briefLabel, armed: pullChip == .brief && briefOffered)
                .frame(height: max(m.minScroll - scroll, 0), alignment: .center)
                .frame(maxWidth: .infinity)
                .offset(y: m.contentHeight + scroll)
        }
    }

    private var briefCapability: Capability? {
        fleet.globalControls.first { $0.id == "new" }
    }

    private var briefOffered: Bool { briefCapability?.usable ?? false }

    /// The gesture is never a dead end. When archserver does not declare `new`
    /// the pull still opens and says why, rather than bouncing back silently.
    private var briefLabel: String {
        guard let capability = briefCapability else {
            return "BRIEFING ISN'T OFFERED BY ARCHSERVER"
        }
        if let refusal = capability.refusal { return refusal.uppercased() }
        return capability.label.uppercased()
    }

    // MARK: - The arbiter
    //
    // One recognizer for the whole surface. It resolves taps itself, because a
    // `Button` inside a row would take the touch before the axis lock could
    // decide whether the finger meant to scroll.

    private func arbiter(_ m: Metrics) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard nav < 0.02 else { return }
                if drag.axis == .none {
                    if hypot(value.translation.width, value.translation.height) < 8 {
                        if !drag.began { begin(value, m) }
                        return
                    }
                    lock(value, m)
                }
                switch drag.axis {
                case .vertical:
                    scroll = m.band(drag.scrollAtStart + value.translation.height)
                    scrollAnchor = scroll
                    pullChip = chip(for: scroll, m)
                case .horizontal:
                    guard let id = drag.row, let agent = fleet[id] else { return }
                    swiped = id
                    swipeX = band(drag.swipeAtStart + value.translation.width, for: agent)
                case .none:
                    break
                }
            }
            .onEnded { value in
                defer { drag = DragArbiter() }
                guard nav < 0.02 else { return }
                switch drag.axis {
                case .vertical: endScroll(value, m)
                case .horizontal: endSwipe(value)
                case .none: endTap(value, m)
                }
            }
    }

    private func begin(_ value: DragGesture.Value, _ m: Metrics) {
        drag.began = true
        // The finger-space value, not the banded one. Grabbing a list that is
        // still bouncing must resume from where the finger would have been, or
        // there is a visible step under the thumb at the moment of contact.
        drag.scrollAtStart = m.unband(scroll)
        drag.swipeAtStart = swipeX
        drag.row = m.row(atViewportY: value.startLocation.y, scroll: scroll)
    }

    private func lock(_ value: DragGesture.Value, _ m: Metrics) {
        if !drag.began { begin(value, m) }
        drag.axis = abs(value.translation.width) > abs(value.translation.height)
            ? .horizontal : .vertical
        // A horizontal drag that starts anywhere but the open row closes it
        // first. Two half-open rows is the state that reads as broken.
        if drag.axis == .horizontal, drag.row != swiped {
            swipeX = 0
            swiped = drag.row
            drag.swipeAtStart = 0
        }
        if drag.axis == .vertical, swiped != nil {
            withAnimation(.snap) { swipeX = 0 }
            swiped = nil
        }
    }

    private func endScroll(_ value: DragGesture.Value, _ m: Metrics) {
        let vy = value.velocity.height
        let committed = pullChip
        pullChip = .none

        if committed == .refresh {
            onRefresh()
        } else if committed == .brief, briefOffered {
            onBrief()
        }

        if scroll > 0 || scroll < m.minScroll {
            // Released outside the bounds: no throw survives, only the return.
            settle(to: m.clamp(scroll), velocity: vy * 0.25, spring: (120, 18))
        } else {
            settle(to: m.clamp(scroll + project(vy)), velocity: vy, spring: (220, 30))
        }
    }

    private func endTap(_ value: DragGesture.Value, _ m: Metrics) {
        // A tap while a row is open closes it and does nothing else. That is
        // the standard behaviour everywhere else on the phone and undoing an
        // accidental swipe must not also navigate.
        if swiped != nil {
            withAnimation(.snap) { swipeX = 0 }
            swiped = nil
            return
        }
        // The header's one control is resolved by the same recognizer as
        // everything else. A `Button` in the header would take the touch before
        // the axis lock could decide whether the finger meant to scroll, which
        // is the whole reason this surface is custom.
        if m.settingsHit(value.startLocation, scroll: scroll) {
            onSettings()
            return
        }
        guard let id = m.row(atViewportY: value.startLocation.y, scroll: scroll)
        else { return }
        onOpen(id)
    }

    private func endSwipe(_ value: DragGesture.Value) {
        guard let id = swiped, let agent = fleet[id] else { return }
        let vx = value.velocity.width
        let x = swipeX
        let end = x + project(vx)
        let left = leftLimit(agent)
        let right = rightLimit(agent)

        // A fling only ever commits the reversible action. `kill` must be
        // tapped and then held (APP-PLAN 9.5) -- this is the gesture-level half
        // of that rule, and it is why only the *first* left control is ever
        // reachable by a throw.
        if left > 0, end < -left - Self.pullThreshold || (vx < -1100 && x < -60) {
            fire(leftControls(agent).first, agent)
            return
        }
        if right > 0, end > right + 66 || (vx > 1100 && x > 50) {
            fire(rightControl(agent), agent)
            return
        }
        if left > 0, end < -left * 0.62 {
            withAnimation(.snap) { swipeX = -left }
            return
        }
        if right > 0, end > Self.pullThreshold {
            withAnimation(.snap) { swipeX = right }
            return
        }
        withAnimation(.snap) { swipeX = 0 }
        swiped = nil
    }

    private func fire(_ capability: Capability?, _ agent: Agent) {
        withAnimation(.snap) { swipeX = 0 }
        swiped = nil
        guard let capability else { return }
        onControl(agent, capability)
    }

    // MARK: - Swipe limits
    //
    // Zero when the server declares nothing for that side, and zero means the
    // row does not move at all. An empty capability list renders as no
    // controls; it never invents one.

    private func leftControls(_ agent: Agent) -> [Capability] {
        // The first two of `stop`, `kill` that are present, in the server's own
        // order -- not in ours.
        agent.capabilities.filter { $0.id == "stop" || $0.id == "kill" }.prefix(2).map { $0 }
    }

    private func rightControl(_ agent: Agent) -> Capability? {
        agent.capabilities.first { $0.id == "retask" }
            ?? agent.capabilities.first { $0.id == "resume" }
    }

    private func leftLimit(_ agent: Agent) -> Double {
        guard !leftControls(agent).isEmpty else { return 0 }
        return agent.presence == .dead || agent.presence == .done ? 132 : 148
    }

    private func rightLimit(_ agent: Agent) -> Double {
        rightControl(agent) == nil ? 0 : 118
    }

    private func band(_ x: Double, for agent: Agent) -> Double {
        let left = -leftLimit(agent)
        let right = rightLimit(agent)
        if x > right { return right + rubber(x - right, 320, 0.62) }
        if x < left { return left - rubber(left - x, 320, 0.62) }
        return x
    }

    // MARK: - Settling

    private func chip(for scroll: Double, _ m: Metrics) -> PullChip {
        if scroll > Self.pullThreshold { return .refresh }
        if scroll < m.minScroll - Self.pullThreshold { return .brief }
        return .none
    }

    /// `initialVelocity` on `interpolatingSpring` is normalised by the distance
    /// being animated, not an absolute rate. Passing the raw finger velocity
    /// makes a short throw explode and a long throw feel dead.
    private func settle(to target: Double, velocity: Double, spring: (Double, Double)) {
        let distance = target - scroll
        let v0 = abs(distance) < 1e-4 ? 0 : velocity / distance
        scrollAnchor = scroll
        withAnimation(.interpolatingSpring(mass: 1, stiffness: spring.0,
                                           damping: spring.1, initialVelocity: v0),
                      completionCriteria: .removed) {
            scroll = target
        } completion: {
            // The travel is over, so the mounted window can close back down to
            // one screenful.
            if scroll == target { scrollAnchor = target }
        }
    }
}

// MARK: - Arbiter state

private enum Axis { case none, vertical, horizontal }

/// Which way this gesture went, and what it was resumed from. One value so a
/// gesture cannot be half-reset: `drag = DragArbiter()` in a `defer` is the
/// whole teardown.
private struct DragArbiter {
    var axis: Axis = .none
    var began = false
    var scrollAtStart: Double = 0
    var swipeAtStart: Double = 0
    var row: AgentID?
}

enum PullChip: Equatable { case none, refresh, brief }

// MARK: - Layout

/// Row tops, heights and bounds, recomputed per render from the roster.
///
/// A value type so it can be built in `body` and handed to every helper without
/// a second source of truth to keep in step -- a row's height depends on
/// whether it is blocked, and that changes underneath the scroll.
private struct Metrics {
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

    /// Overscroll is rubber-banded against the screen height with c = 0.62, so
    /// no amount of finger travel pulls the surface off the screen.
    func band(_ v: Double) -> Double {
        if v > 0 { return rubber(v, viewport, 0.62) }
        if v < minScroll { return minScroll - rubber(minScroll - v, viewport, 0.62) }
        return v
    }

    func unband(_ v: Double) -> Double {
        if v > 0 { return unrubber(v, viewport, 0.62) }
        if v < minScroll { return minScroll - unrubber(minScroll - v, viewport, 0.62) }
        return v
    }

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
    func visible(from: Double, to: Double) -> [AgentID] {
        let lo = min(from, to)
        let hi = max(from, to)
        return tops.indices.filter {
            let low = tops[$0] + lo
            let high = tops[$0] + hi
            return high + heights[$0] > -heights[$0] && low < viewport + heights[$0]
        }.map { order[$0] }
    }
}

// MARK: - Chrome

private struct PullLabel: View {
    let text: String
    let armed: Bool

    var body: some View {
        Text(text)
            .text(.label(10))
            .monospacedDigit()
            .foregroundStyle(armed ? Theme.ink : Theme.ink3)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(armed ? Theme.line2 : Theme.ink5)
            )
            .animation(.settle, value: armed)
    }
}

private struct FleetHeader: View {
    let fleet: Fleet
    let reachable: Reachability
    let refreshing: Bool
    let chip: PullChip

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

            // Hit-tested by the surface's own recognizer, not by a `Button`.
            // See `Metrics.settingsHit`.
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

    /// The chip reads `REFRESH` while the pull is armed, then the age of the
    /// data. The age is the honest readout when archserver is unreachable --
    /// the counts are still true, they are just true about an older moment.
    private var counts: String {
        let total = fleet.agents.count
        let blocked = fleet.blockedCount
        var out = "\(total) AGENT\(total == 1 ? "" : "S")"
        if blocked > 0 { out += " · \(blocked) BLOCKED" }
        if refreshing || chip == .refresh {
            out += " · REFRESH"
        } else if case .stale(let since, _) = reachable {
            out += since.map { " · \(ago($0).uppercased()) OLD" } ?? " · NO CONTACT"
        }
        return out
    }
}
