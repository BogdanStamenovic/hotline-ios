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
    /// The sheet's own progress value. Same mechanism, its own scalar: two
    /// seams that share a gesture vocabulary are still two seams.
    @State private var sheet: Double = 0
    @State private var sheetKind: SheetKind?
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
    /// Which capability is in flight, so its row can say so and a second tap
    /// cannot fire a duplicate.
    @State private var busyControl: String?
    @State private var commit = 0

    /// 1 normally, 0 under Reduce Motion. It multiplies every positional term,
    /// so the staging survives as pure opacity rather than disappearing.
    private var mo: Double { reduceMotion ? 0 : 1 }

    enum SheetKind: Equatable {
        case controls(AgentID)
        case brief
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            FleetLayer(
                fleet: fleet, nav: nav, hero: open, mo: mo,
                reachable: fleet.reachable, refreshing: refreshing,
                titleFrames: $titleFrames,
                onOpen: enter, onRefresh: refresh, onBrief: brief, onControl: dispatch,
                onSettings: { settings = true })
                .staged(.fleet, nav, mo)
                .allowsHitTesting(nav < 0.02 && sheetKind == nil)
                .zIndex(Z.fleet)

            Color.black
                .ignoresSafeArea()
                .staged(.scrim, nav, mo)
                .zIndex(Z.scrim)

            if let open, let agent = fleet[open] {
                ChannelLayer(agent: agent, channel: fleet.channel(for: open),
                             nav: nav, mo: mo,
                             onBack: leave, onDrag: scrub,
                             onControls: { present(.controls(open)) },
                             onContinue: { continueAfterCompact(agent) })
                    .id(open)
                    .allowsHitTesting(sheetKind == nil)
                    .zIndex(Z.channel)
            }

            if let kind = sheetKind { sheetLayer(kind).zIndex(Z.sheet) }

            OverlayLayer(
                hero: open.flatMap { fleet[$0] }, nav: nav, mo: mo,
                from: heroFrom,
                reachable: fleet.reachable, toast: toast)
                .zIndex(Z.overlay)
        }
        .coordinateSpace(name: Space.shell)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsSheet() }
        // One committed control, one pulse. APP-PLAN 4.8's budget: everything
        // single-pulse is declarative, and there is no generator lifetime to
        // manage anywhere in this build.
        .sensoryFeedback(.impact(weight: .medium), trigger: commit)
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
        // Start the cache read now, while the transition plays, so the thread
        // is painted before it is legible.
        fleet.warm(id)
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

    // MARK: - The sheet

    @ViewBuilder
    private func sheetLayer(_ kind: SheetKind) -> some View {
        switch kind {
        case .controls(let id):
            if let agent = fleet[id] {
                ControlSheet(
                    agent: agent, progress: sheet, busy: busyControl,
                    onDismiss: dismissSheet,
                    onDispatch: { dispatch(agent, $0) },
                    onRetask: { text, stopFirst in retask(agent, text, stopFirst) },
                    onKill: { kill(agent) },
                    onDrag: slide)
            }
        case .brief:
            BriefSheet(capability: fleet.globalControls.first { $0.id == "new" },
                       progress: sheet, busy: busyControl != nil,
                       onDismiss: dismissSheet, onSend: brief(task:), onDrag: slide)
        }
    }

    private func present(_ kind: SheetKind) {
        sheetKind = kind
        withAnimation(.glide) { sheet = 1 }
    }

    private func dismissSheet() {
        withAnimation(.navBack, completionCriteria: .removed) {
            sheet = 0
        } completion: {
            if sheet == 0 { sheetKind = nil }
        }
    }

    private func slide(_ phase: SheetPhase) {
        switch phase {
        case .move(let progress):
            sheet = progress
        case .release(let velocityPerSecond):
            let predicted = sheet + project(velocityPerSecond)
            let target: Double = predicted < 0.55 ? 0 : 1
            let distance = target - sheet
            let v0 = abs(distance) < 1e-4 ? 0 : velocityPerSecond / distance
            withAnimation(.interpolatingSpring(mass: 1,
                                               stiffness: target == 0 ? 300 : 220,
                                               damping: target == 0 ? 34 : 30,
                                               initialVelocity: v0),
                          completionCriteria: .removed) {
                sheet = target
            } completion: {
                if sheet == 0 { sheetKind = nil }
            }
        }
    }

    // MARK: - Control dispatch
    //
    // The app knows the endpoint and body shape for each id. It knows nothing
    // about which capabilities exist, what they are called, or whether they are
    // enabled -- that is `Agent.controls`, and it is rendered as it arrives.

    private func dispatch(_ agent: Agent, _ capability: Capability) {
        // A disabled control that does nothing when tapped is
        // indistinguishable from a broken one, so the refusal is the response.
        if let refusal = capability.refusal {
            toast = Toast(text: "\(capability.label): \(refusal)")
            return
        }
        guard busyControl == nil else { return }
        busyControl = capability.id
        Task {
            defer { busyControl = nil }
            switch capability.id {
            case "stop": await stop(agent)
            case "resume": await resume(agent)
            case "compact": await compact(agent)
            case "kill":
                // Never reachable from a tap: the sheet routes kill through the
                // hold, and a fling can only ever commit the reversible action.
                toast = Toast(text: "Kill has to be held.")
            case "retask":
                present(.controls(agent.name))
            case "new":
                present(.brief)
            default:
                toast = Toast(text: "\(capability.label): this build can't do that yet.")
            }
        }
    }

    private func stop(_ agent: Agent) async {
        switch await fleet.stop(agent.name) {
        case .ok(let result):
            commit &+= 1
            toast = Toast(text: result.interrupted ? "Stopped — the session is still there."
                                                   : "Nothing to interrupt.")
        case .failed(let why):
            // A 409 from /stop says "already interrupting", and rendering that
            // beats rendering "archserver said 409".
            toast = Toast(text: why)
        }
    }

    private func kill(_ agent: Agent) {
        guard busyControl == nil else { return }
        busyControl = "kill"
        Task {
            defer { busyControl = nil }
            switch await fleet.kill(agent.name) {
            case .ok(let result):
                commit &+= 1
                dismissSheet()
                toast = Toast(text: "Killed — \(result.outcome)")
            case .failed(let why):
                toast = Toast(text: why)
            }
        }
    }

    private func resume(_ agent: Agent) async {
        switch await fleet.resume(agent.name) {
        case .ok(let result):
            commit &+= 1
            toast = Toast(text: result.fromHandoff == true
                          ? "Resumed from its handoff."
                          : "Resumed.")
        case .failed(let why):
            toast = Toast(text: why)
        }
    }

    private func retask(_ agent: Agent, _ text: String, _ stopFirst: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, busyControl == nil else { return }
        busyControl = "retask"
        Task {
            defer { busyControl = nil }
            // The token is what lets the resulting `you` event be recognised as
            // this write rather than popping the composer's optimistic bubble.
            let token = UUID().uuidString
            switch await fleet.retask(agent.name, text: trimmed,
                                      stopFirst: stopFirst, clientToken: token) {
            case .ok(let result):
                commit &+= 1
                dismissSheet()
                // `queued` and `delivered` are different outcomes and read
                // differently. "It will start after the current turn" is not
                // "started".
                toast = Toast(text: result.queued && !result.delivered
                              ? "Queued — it will start after the current turn."
                              : "Started.")
            case .failed(let why):
                toast = Toast(text: why)
            }
        }
    }

    /// **It reports what it actually did.** `preTokens`, `postTokens` and
    /// `durationMs` are read out of the transcript's `compact_boundary` record
    /// -- not a timer and not an estimate -- so the thread gets the numbers
    /// rather than a generic success state.
    ///
    /// The context bar's fall is deliberately *not* computed from `postTokens`:
    /// the app has no window size and would be guessing. It waits ~5 s for the
    /// next roster sample and lets the drop be a real measurement.
    private func compact(_ agent: Agent) async {
        let channel = fleet.channel(for: agent.name)
        switch await fleet.compact(agent.name) {
        case .ok(let result):
            commit &+= 1
            dismissSheet()
            channel.note(compactSentence(result), kind: result.compacted ? .state : .error)
            // `resumed: false` is a valid, honest outcome -- the server
            // declined to fire a continuation. It is not an error and not a
            // success, and it gets an affordance rather than an apology.
            if result.compacted, !result.resumed { channel.offerContinue() }
        case .failed(let why):
            toast = Toast(text: why)
        }
    }

    /// The `Continue` button a `resumed: false` compaction leaves behind. It
    /// issues an ordinary retask -- which is exactly what the server would have
    /// injected had it fired the continuation itself.
    private func continueAfterCompact(_ agent: Agent) {
        fleet.channel(for: agent.name).takeContinueOffer()
        retask(agent, "Continue where you left off.", false)
    }

    // MARK: - Brief a new agent

    /// The pull past the bottom of the list. **The gesture is never a dead
    /// end**: if archserver does not offer `new`, the sheet still opens and
    /// says why instead of showing a field.
    private func brief() {
        present(.brief)
    }

    private func brief(task: String) {
        let trimmed = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, busyControl == nil else { return }
        busyControl = "new"
        Task {
            defer { busyControl = nil }
            switch await fleet.brief(task: trimmed) {
            case .ok(let result):
                commit &+= 1
                dismissSheet()
                toast = Toast(text: "Briefed \(result.agent).")
            case .failed(let why):
                toast = Toast(text: why)
            }
        }
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
