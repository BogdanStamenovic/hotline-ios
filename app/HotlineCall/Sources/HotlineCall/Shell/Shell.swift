import SwiftUI

/// The whole app, as one `ZStack` of layers over a handful of progress values.
///
/// **There is no `NavigationStack`.** The list -> channel transition is not a
/// push; it is an orchestrated disassembly driven by one `Double` that a drag
/// can scrub backwards and forwards at whatever speed the thumb chooses.
/// `NavigationStack` owns its own transition and its own interactive pop and
/// neither is reachable as a scalar we can read, so building on it would mean
/// building on a transition we cannot see, in a container that fights us for
/// the left-edge gesture.
///
/// What that gives up, stated so nobody rediscovers it as a bug: the system
/// back swipe, large-title behaviour, `NavigationPath` restoration, and
/// automatic keyboard avoidance in the pushed view. The first three are things
/// this app does not want.
struct Shell: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one value the whole scene change is a pure function of. Nothing in
    /// the transition has its own timeline, because a second timeline is a
    /// thing that can drift out of sync with the first.
    @State private var nav: Double = 0
    @State private var open: AgentID?
    @State private var titleFrames: [AgentID: CGRect] = [:]
    /// The hero's start rect, snapshotted at the beginning of *every*
    /// transition, forward and backward: the row may have moved since the last
    /// one (reorder, unpin, scroll) and a flight that starts from a stale rect
    /// is the version of this bug nobody reports.
    @State private var heroFrom: CGRect = .zero
    @State private var toast: Toast?
    @State private var refreshing = false
    @State private var settings = false

    /// 1 normally, 0 under Reduce Motion. It multiplies every positional term,
    /// so the staging survives as pure opacity rather than disappearing.
    private var mo: Double { reduceMotion ? 0 : 1 }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            FleetLayer(
                fleet: fleet, nav: nav, hero: open, mo: mo,
                reachable: fleet.reachable, refreshing: refreshing,
                titleFrames: $titleFrames,
                onOpen: enter, onRefresh: refresh, onBrief: brief, onControl: control,
                onSettings: { settings = true })
                .staged(.fleet, nav, mo)
                .allowsHitTesting(nav < 0.02)
                .zIndex(Z.fleet)

            Color.black
                .ignoresSafeArea()
                .staged(.scrim, nav, mo)
                .zIndex(Z.scrim)

            if let open, let agent = fleet[open] {
                ChannelLayer(agent: agent, nav: nav, mo: mo,
                             onBack: leave, onDrag: scrub)
                    .id(open)
                    .zIndex(Z.channel)
            }

            OverlayLayer(
                hero: open.flatMap { fleet[$0] }, nav: nav, mo: mo,
                from: heroFrom,
                reachable: fleet.reachable, toast: toast)
                .zIndex(Z.overlay)
        }
        .coordinateSpace(name: Space.shell)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsSheet() }
        .task { await launch() }
        // The only thing that starts or stops the roster stream is the app
        // becoming, or ceasing to be, active. Half of bug 1: the old app
        // refreshed from `.task`, which fires once per store identity and
        // therefore once per foregrounded lifetime.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { fleet.begin() } else { fleet.suspend() }
        }
        .onChange(of: toast?.id) { _, _ in expireToast() }
    }

    // MARK: - Lifecycle

    private func launch() async {
        refreshing = true
        await fleet.hardRefresh()
        refreshing = false
        fleet.begin()
    }

    private func refresh() {
        guard !refreshing else { return }
        Task {
            refreshing = true
            await fleet.hardRefresh()
            refreshing = false
        }
    }

    // MARK: - The scene change

    private func enter(_ id: AgentID) {
        heroFrom = titleFrames[id] ?? .zero
        open = id
        fleet.foreground(id)
        withAnimation(.glide) { nav = 1 }
    }

    private func leave() {
        fleet.foreground(nil)
        withAnimation(.navBack, completionCriteria: .removed) {
            nav = 0
        } completion: {
            // Guarded because a retarget forward mid-flight still fires this
            // completion, and tearing the channel down under a transition that
            // has changed its mind would be the visible version of that race.
            if nav == 0 { open = nil }
        }
    }

    /// The interactive pop. `.onChanged` writes `nav` with **no animation** --
    /// the finger owns it, 1:1 -- and that unanimated write is also what
    /// cancels any running transition and hands position over.
    private func scrub(_ phase: ScrubPhase) {
        switch phase {
        case .begin:
            if let open { heroFrom = titleFrames[open] ?? heroFrom }
        case .move(let progress):
            nav = progress
        case .release(let velocityPerSecond):
            let predicted = nav + project(velocityPerSecond)
            let target: Double = predicted < 0.55 ? 0 : 1
            let distance = target - nav
            let v0 = abs(distance) < 1e-4 ? 0 : velocityPerSecond / distance
            if target == 0 { fleet.foreground(nil) }
            withAnimation(
                .interpolatingSpring(mass: 1,
                                     stiffness: target == 0 ? 300 : 220,
                                     damping: target == 0 ? 34 : 30,
                                     initialVelocity: v0),
                completionCriteria: .removed
            ) {
                nav = target
            } completion: {
                if nav == 0 { open = nil }
            }
        case .cancel:
            leave()
        }
    }

    // MARK: - Controls, not yet dispatched

    /// Step 2 renders the control surface; step 6 sends it. A refusal is pure
    /// rendering and ships now -- a disabled control that says nothing when
    /// tapped is indistinguishable from a broken one.
    private func control(_ agent: Agent, _ capability: Capability) {
        guard let refusal = capability.refusal else { return }
        toast = Toast(text: "\(capability.label): \(refusal)")
    }

    private func brief() {
        guard let capability = fleet.globalControls.first(where: { $0.id == "new" }) else { return }
        if let refusal = capability.refusal { toast = Toast(text: refusal) }
    }

    private func expireToast() {
        guard let current = toast else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast?.id == current.id { toast = nil }
        }
    }
}

/// What the left-edge recognizer is telling `Shell`. An enum rather than three
/// closures so a phase cannot be handled in one place and forgotten in another.
enum ScrubPhase {
    case begin
    case move(Double)
    /// Progress per second, already normalised against the viewport width.
    case release(Double)
    case cancel
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
