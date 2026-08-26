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
    /// The **presented** top and height of every row, as opposed to the target
    /// layout `Metrics` computes.
    ///
    /// They have to be separate. The re-sort is a beat in APP-PLAN 4.6's
    /// choreography with its own two springs and its own propagating delays;
    /// `fleet.order` changing is a model write, and a view that reads it
    /// directly jumps to the new layout in one frame with no way to stage
    /// anything. Rows are drawn from here and animated into it explicitly.
    @State private var placed: [Slot: Placement] = [:]
    /// Retired agents live in their own collapsed section (APP-PLAN 8.1). Closed
    /// by default: it is the section for things he has decided not to look at.
    @State private var retiredOpen = false

    /// The distance a pull past an edge must project to before it means
    /// something. Both edges share it so the two gestures feel like one
    /// mechanism with two meanings.
    private static let pullThreshold: Double = 74

    var body: some View {
        GeometryReader { geo in
            let metrics = Metrics(
                fleet: fleet, retiredOpen: retiredOpen,
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
            .onAppear { placed = metrics.targets }
            // The re-sort beat. `fleet.mover` names the climbing row; everything
            // else parts around it, and the two springs must not be collapsed
            // into one (APP-PLAN 4.2).
            .onChange(of: metrics.signature) { _, _ in restage(metrics) }
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
        let heroIndex = hero.flatMap { m.index(of: .agent($0)) }
        // Keyed by agent, never by index. Index identity would recycle a row
        // view onto a different agent when the roster reorders -- which is
        // exactly what a blocked agent climbing the list does -- taking that
        // row's animation state with it.
        ForEach(m.visible(from: scrollAnchor, to: scroll, placed: placed), id: \.self) { slot in
            let box = placed[slot] ?? m.targets[slot] ?? Placement(top: 0, height: rowHeight)
            Group {
                switch slot {
                case .agent(let id):
                    if let agent = fleet[id] {
                        FleetRow(
                            agent: agent,
                            height: box.height,
                            isHero: hero == id,
                            swipeX: swiped == id ? swipeX : 0,
                            beats: fleet.beats[id] ?? ArrivalBeats(),
                            settled: fleet.shown(id),
                            question: fleet.questions[id],
                            nav: nav, mo: mo,
                            titleFrame: $titleFrames,
                            onControl: { onControl(agent, $0) })
                        .frame(width: width, height: box.height, alignment: .topLeading)
                        .staged(role(for: m.index(of: slot) ?? 0, heroIndex: heroIndex), nav, mo)
                    }
                case .retiredHeader:
                    RetiredHeader(count: fleet.retired.count, open: retiredOpen)
                        .frame(width: width, height: box.height, alignment: .leading)
                }
            }
            .offset(y: box.top + scroll)
            // The mover is above everything for the duration of the pass, and
            // a blocked row is above an ordinary one the rest of the time.
            .zIndex(zIndex(for: slot))
        }
    }

    private func zIndex(for slot: Slot) -> Double {
        guard case .agent(let id) = slot else { return 0 }
        if fleet.beats[id]?.lifted == true { return 3 }
        return fleet.shown(id) ? 1 : 0
    }

    private func role(for i: Int, heroIndex: Int?) -> Role {
        guard let heroIndex else { return .row(d: 0) }
        return i == heroIndex ? .heroRow : .row(d: i - heroIndex)
    }

    // MARK: - The re-sort, as APP-PLAN 4.6's fourth beat

    /// Animate every row from where it is drawn to where it now belongs.
    ///
    /// The mover climbs on `climb` (w0 18.4); every other row parts on `float`
    /// (w0 11.0) with a delay that propagates outward from it -- rows above
    /// `min(-d, 8) * 26 ms`, rows below `min(d, 8) * 14 ms`. Watching the
    /// blocked row jump the queue rather than the queue tidily re-sorting is
    /// the entire point, and a single spring for both destroys it silently.
    ///
    /// With no mover -- an ordinary roster change, an agent finishing, a retire
    /// -- everything snaps together and there is no stagger to read.
    private func restage(_ m: Metrics) {
        let targets = m.targets
        let moverSlot = fleet.mover.map { Slot.agent($0) }
        let moverIndex = moverSlot.flatMap { m.index(of: $0) }

        // Rows that have gone stop being drawn; rows that are new appear where
        // they belong rather than flying in from a position they never had.
        placed = placed.filter { targets[$0.key] != nil }
        for (slot, box) in targets where placed[slot] == nil { placed[slot] = box }

        for (slot, box) in targets {
            guard placed[slot] != box else { continue }
            let animation: Animation
            if let moverIndex, let index = m.index(of: slot) {
                if slot == moverSlot {
                    animation = .climb
                } else {
                    let d = index - moverIndex
                    let delay = d < 0 ? Double(min(-d, 8)) * 0.026 : Double(min(d, 8)) * 0.014
                    animation = .float.delay(delay)
                }
            } else {
                animation = .snap
            }
            withAnimation(mo == 0 ? .easeOut(duration: 0.16) : animation) {
                placed[slot] = box
            }
        }
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
        drag.row = m.agent(atViewportY: value.startLocation.y, scroll: scroll, placed: placed)
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
        switch m.slot(atViewportY: value.startLocation.y, scroll: scroll, placed: placed) {
        case .agent(let id):
            onOpen(id)
        case .retiredHeader:
            withAnimation(.glide) { retiredOpen.toggle() }
        case nil:
            break
        }
    }

    /// APP-PLAN 4.7's table, decided by `swipeOutcome` in `Theme/Scalars.swift`.
    ///
    /// It lives there rather than here for the reason the rest of this app's
    /// decisions do: that file imports Foundation alone, so `app/wiretest/run.sh`
    /// *executes* the table instead of a build log asserting it. This one was
    /// worth moving — as shipped, the projected-end commit test fired `stop` on
    /// any release faster than 148 pt/s, which is every swipe that opens the
    /// row. See the note on `swipeOutcome`.
    private func endSwipe(_ value: DragGesture.Value) {
        guard let id = swiped, let agent = fleet[id] else { return }
        let left = leftLimit(agent)
        let right = rightLimit(agent)

        switch swipeOutcome(x: swipeX, velocity: value.velocity.width,
                            leftLimit: left, rightLimit: right) {
        // A fling only ever commits the reversible action. `kill` must be
        // tapped and then held (APP-PLAN 9.5) -- this is the gesture-level half
        // of that rule, and it is why only the *first* left control is ever
        // reachable by a throw.
        case .fireLeft:
            fire(leftControls(agent).first, agent)
        case .fireRight:
            fire(rightControl(agent), agent)
        case .openLeft:
            withAnimation(.snap) { swipeX = -left }
        case .openRight:
            withAnimation(.snap) { swipeX = right }
        case .closed:
            withAnimation(.snap) { swipeX = 0 }
            swiped = nil
        }
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

/// One thing the list can draw. An enum rather than an `AgentID` because the
/// retired section's own header occupies a row and has to be hit-tested,
/// virtualised and placed exactly like everything else.
enum Slot: Hashable {
    case agent(AgentID)
    case retiredHeader
}

/// Where a row is drawn. Both terms travel together, because the blocked row
/// grows 88 -> 116 pt *while* it climbs and animating them on two springs would
/// let the row's bottom edge lead its top.
struct Placement: Equatable {
    var top: Double
    var height: Double
}

/// Row tops, heights and bounds, recomputed per render from the roster.
///
/// A value type so it can be built in `body` and handed to every helper without
/// a second source of truth to keep in step -- a row's height depends on
/// whether it is blocked, and that changes underneath the scroll.
private struct Metrics {
    let slots: [Slot]
    let viewport: Double
    let width: Double
    let headerHeight: Double
    let tops: [Double]
    let heights: [Double]
    let contentHeight: Double
    /// What `placed` is animated towards.
    let targets: [Slot: Placement]

    init(fleet: Fleet, retiredOpen: Bool, viewport: Double, width: Double,
         headerHeight: Double, rowHeight: Double, blockedRowHeight: Double) {
        var slots: [Slot] = fleet.order.map { .agent($0) }
        if !fleet.retired.isEmpty {
            slots.append(.retiredHeader)
            // Retired agents keep their live dot in there, because one of them
            // may still be running: retiring is visibility, not termination.
            if retiredOpen { slots += fleet.retired.map { .agent($0.name) } }
        }
        self.slots = slots
        self.viewport = viewport
        self.width = width
        self.headerHeight = headerHeight

        var tops: [Double] = []
        var heights: [Double] = []
        var targets: [Slot: Placement] = [:]
        var y = headerHeight
        for slot in slots {
            let h: Double
            switch slot {
            // The *settled* flag, not the roster's: a blocked agent whose
            // own beat has not run yet must not have already grown.
            case .agent(let id): h = fleet.shown(id) ? blockedRowHeight : rowHeight
            case .retiredHeader: h = 52
            }
            tops.append(y)
            heights.append(h)
            targets[slot] = Placement(top: y, height: h)
            y += h
        }
        self.tops = tops
        self.heights = heights
        self.targets = targets
        // A run-out below the last row. Without it the last row sits against
        // the home indicator and cannot be swiped without the system gesture
        // taking the touch.
        self.contentHeight = y + 96
    }

    /// Everything a layout change could be. Cheap to compare and it moves on
    /// exactly the three things that restage the list: which rows exist, in
    /// what order, at what height.
    var signature: [Double] { tops + heights + [Double(slots.count)] }

    var minScroll: Double { min(0, viewport - contentHeight) }

    func height(at i: Int) -> Double { heights[i] }
    func top(at i: Int) -> Double { tops[i] }
    func index(of slot: Slot) -> Int? { slots.firstIndex(of: slot) }

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

    /// Which row a touch landed on, measured against where the row is actually
    /// **drawn** rather than where it belongs -- a finger that lands on a row
    /// mid-climb must hit the row it is looking at.
    func slot(atViewportY y: Double, scroll: Double, placed: [Slot: Placement]) -> Slot? {
        let contentY = y - scroll
        for (i, slot) in slots.enumerated() {
            let box = placed[slot] ?? Placement(top: tops[i], height: heights[i])
            if contentY >= box.top && contentY < box.top + box.height { return slot }
        }
        return nil
    }

    func agent(atViewportY y: Double, scroll: Double, placed: [Slot: Placement]) -> AgentID? {
        if case .agent(let id) = slot(atViewportY: y, scroll: scroll, placed: placed) { return id }
        return nil
    }

    /// Only what can be on screen, plus one row of margin either side -- and
    /// anything still travelling, which would otherwise be culled halfway
    /// through the one animation the list exists to show.
    func visible(from: Double, to: Double, placed: [Slot: Placement]) -> [Slot] {
        let lo = min(from, to)
        let hi = max(from, to)
        return slots.indices.filter {
            let slot = slots[$0]
            if let box = placed[slot], box != targets[slot] { return true }
            let low = tops[$0] + lo
            let high = tops[$0] + hi
            return high + heights[$0] > -heights[$0] && low < viewport + heights[$0]
        }.map { slots[$0] }
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

/// The collapsed `Retired (4)` section (APP-PLAN 8.1).
///
/// **Nothing about it is styled as destructive.** No `sig`, no warning colour:
/// retiring destroys nothing, and dressing it up as deletion would make the two
/// operations look like two strengths of the same thing -- which is precisely
/// what SERVER-PLAN §3 says the surface must not do.
private struct RetiredHeader: View {
    let count: Int
    let open: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("RETIRED · \(count)")
                .text(.label(10))
                .monospacedDigit()
                .foregroundStyle(Theme.ink3)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.ink3)
                .rotationEffect(.degrees(open ? 0 : -90))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.edge)
        .frame(maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Retired, \(count) agents, \(open ? "expanded" : "collapsed")")
        .accessibilityAddTraits(.isButton)
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
                // Beat 0 of an arrival. It sweeps in from the left over the
                // first 34 % of 1 500 ms, then the origin flips and it collapses
                // to the right -- one value, so the flip cannot desync from the
                // scale, and 0 the rest of the time so it occupies no space it
                // has not been given a reason to.
                Rectangle()
                    .fill(Theme.sig)
                    .frame(height: 2)
                    .scaleEffect(x: fleet.sweep <= 1 ? fleet.sweep : 2 - fleet.sweep,
                                 anchor: fleet.sweep <= 1 ? .leading : .trailing)
                    .frame(height: fleet.sweep > 0 ? 2 : 0)
                    .accessibilityHidden(true)
                // The counts catch up at the 820 ms beat, by blur-crossfade,
                // *after* the row has said what happened.
                BlurSwap(text: counts) { line in
                    Text(line)
                        .text(.label(11))
                        .monospacedDigit()
                        .foregroundStyle(stale ? Theme.ink4 : Theme.ink3)
                        .animation(.enter, value: stale)
                }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)

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
        // `fleet.counts`, not `fleet.agents.count`: the numbers are held back
        // to the 820 ms beat while an arrival is playing.
        let total = fleet.counts.total
        let blocked = fleet.counts.blocked
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
