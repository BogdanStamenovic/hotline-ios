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
    @Environment(Fleet.self) var fleet
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    /// The one value the whole scene change is a pure function of. Nothing in
    /// the transition has its own timeline, because a second timeline is a
    /// thing that can drift out of sync with the first.
    @State private var nav: Double = 0
    /// The sheet's own progress value. Same mechanism, its own scalar: two
    /// seams that share a gesture vocabulary are still two seams.
    @State private var sheet: Double = 0
    @State private var sheetKind: SheetKind?
    @State var open: AgentID?
    @State private var titleFrames: [AgentID: CGRect] = [:]
    /// The hero's start rect, snapshotted at the beginning of *every*
    /// transition, forward and backward: the row may have moved since the last
    /// one (reorder, unpin, scroll) and a flight that starts from a stale rect
    /// is the version of this bug nobody reports.
    @State private var heroFrom: CGRect = .zero
    @State var toast: Toast?
    @State private var refreshing = false
    @State private var settings = false
    /// Which capability is in flight, so its row can say so and a second tap
    /// cannot fire a duplicate.
    @State var busyControl: String?
    @State var commit = 0

    // ---- step 7: the news, once it has travelled -------------------------
    @State private var signal: Signal?

    // ---- step 8: the map, on its own progress value ----------------------
    @State private var map: Double = 0
    @State private var mapOpen = false

    // ---- step 9: the atomic lock and the card's three tracks -------------
    //
    // `atomic` is `@State` on `Shell` because it is a property of the
    // presentation, not of the data. While it is non-nil every recognizer on
    // every layer returns immediately, every control is disabled, the arrival
    // choreography is queued rather than dropped, and the feed keeps running
    // with its pages parked in `holdback`.
    @State var atomic: AtomicRun?
    @State var reveal: Double = 0
    @State var exitInset: Double = 0
    @State var wordIn: Double = 0
    @State var subIn: Double = 0
    /// Flow A's pre-roll: the answer card's own `slamGo`.
    @State var committing = false
    /// Bumped after an atomic run so the channel replays its own arrival --
    /// APP-PLAN 9.7's self-cut, which is a hard cut and deliberately not a no-op.
    @State var sceneEpoch = 0

    // ---- step 10 / 12.2 --------------------------------------------------
    /// When he backed out of each channel. The auto-open rule's third
    /// condition: backing out is him saying no, and opening it again
    /// immediately is arguing.
    @State private var backedOutAt: [AgentID: Date] = [:]
    @State private var leftAt: Date?
    @State private var launched = false

    /// 1 normally, 0 under Reduce Motion. It multiplies every positional term,
    /// so the staging survives as pure opacity rather than disappearing.
    var mo: Double { reduceMotion ? 0 : 1 }

    /// The slam card keeps its *sequence* under Reduce Motion and compresses the
    /// durations, so it needs the flag itself rather than `mo` (APP-PLAN 9.8).
    var reduceMotionValue: Bool { reduceMotion }

    enum SheetKind: Equatable {
        case controls(AgentID)
        case brief
        /// The map's cursor hands in a `before_seq`; `nil` is the whole history.
        case purge(AgentID, Int?)
    }

    /// While the card holds the lock nothing else may be touched.
    private var locked: Bool { atomic != nil }

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
                .allowsHitTesting(nav < 0.02 && sheetKind == nil && !locked)
                .zIndex(Z.fleet)

            Color.black
                .ignoresSafeArea()
                .staged(.scrim, nav, mo)
                .zIndex(Z.scrim)

            if let open, let agent = fleet[open] {
                let channel = fleet.channel(for: open)
                ChannelLayer(agent: agent, channel: channel,
                             nav: nav, mo: mo, cut: sceneEpoch,
                             committing: committing,
                             onBack: leave, onDrag: scrub,
                             onControls: { present(.controls(open)) },
                             onContinue: { continueAfterCompact(agent) },
                             onMapDrag: slideMap,
                             onAnswer: { answer(agent, channel, $0) })
                    .id(open)
                    .allowsHitTesting(sheetKind == nil && !locked && map < 0.5)
                    // Behind the map it is pushed back and softened rather than
                    // merely dimmed, because it *is* behind something now.
                    .brightness(-0.5 * map)
                    .blur(radius: (map * 5).rounded())
                    .offset(y: -map * 10)
                    .scaleEffect(1 - 0.03 * map)
                    .zIndex(Z.channel)

                if mapOpen {
                    MapLayer(agent: agent, channel: channel, progress: map, mo: mo,
                             onDrag: slideMap,
                             onPurgeBefore: { present(.purge(open, $0)) })
                        .allowsHitTesting(!locked)
                        .zIndex(Z.map)
                }
            }

            if let kind = sheetKind { sheetLayer(kind).allowsHitTesting(!locked).zIndex(Z.sheet) }

            OverlayLayer(
                hero: open.flatMap { fleet[$0] }, nav: nav, mo: mo,
                from: heroFrom,
                reachable: fleet.reachable, toast: toast,
                signal: signal,
                onSignalTap: openSignal,
                onSignalDismiss: { signal = nil })
                .zIndex(Z.overlay)

            if let atomic {
                SlamLayer(run: atomic, reveal: reveal, exit: exitInset,
                          wordIn: wordIn, subIn: subIn, mo: mo)
                    .zIndex(Z.slam)
            }
        }
        .coordinateSpace(name: Space.shell)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) {
            SettingsSheet(contextReported: fleet.contextReported,
                          onFreeUpSpace: { await fleet.freeUpSpace() },
                          onMeasure: { await fleet.cacheBytes() })
        }
        // One committed control, one pulse. APP-PLAN 4.8's budget: everything
        // single-pulse is declarative, and there is no generator lifetime to
        // manage anywhere in this build.
        .sensoryFeedback(.impact(weight: .medium), trigger: commit)
        // One pulse per blocked arrival, at beat 0.
        .sensoryFeedback(.impact(weight: .medium), trigger: fleet.pulse)
        .task { await launch() }
        // The only thing that starts or stops the roster stream is the app
        // becoming, or ceasing to be, active. Half of bug 1: the old app
        // refreshed from `.task`, which fires once per store identity and
        // therefore once per foregrounded lifetime.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                fleet.begin()
                Task { await returned() }
            } else {
                leftAt = .now
                fleet.suspend()
            }
        }
        .onChange(of: toast?.id) { _, _ in expireToast() }
        // `Fleet` cannot read the environment, and the arrival's beats have to
        // compress under Reduce Motion without losing their order.
        .onAppear { fleet.reduceMotion = reduceMotion }
        .onChange(of: reduceMotion) { _, on in fleet.reduceMotion = on }
        // The 980 ms beat, landing on whichever surface is visible.
        .onChange(of: fleet.news?.id) { _, _ in deliverNews() }
    }

    // MARK: - Lifecycle

    private func launch() async {
        refreshing = true
        await fleet.hardRefresh()
        refreshing = false
        fleet.begin()
        guard !launched else { return }
        launched = true
        autoOpenIfOwed(.cold)
    }

    /// Coming back from the background. The roster is re-fetched first, because
    /// the rule is about what is true *now* rather than what was true when he
    /// put the phone down.
    private func returned() async {
        guard let left = leftAt else { return }
        let away = Date.now.timeIntervalSince(left)
        leftAt = nil
        await fleet.hardRefresh()
        autoOpenIfOwed(.resumed(after: away))
    }

    /// APP-PLAN 12.2. The three conditions are `autoOpen(in:launch:backedOutAt:)`
    /// in `Wire/Rules.swift`, where they are pure and therefore actually
    /// executed by `app/wiretest/run.sh`.
    ///
    /// **It runs the same transition his tap runs.** The app performs the
    /// gesture rather than cutting to a screen, which is the difference between
    /// it feeling like it moved and it feeling like it lost his place.
    private func autoOpenIfOwed(_ how: Launch) {
        guard open == nil, sheetKind == nil, !locked else { return }
        guard let target = autoOpen(in: fleet.agents, launch: how,
                                    backedOutAt: backedOutAt) else { return }
        Task {
            // The transition it runs is the one a tap runs, and that one lifts
            // the row's own name out of the list -- which needs the row to have
            // been measured. On a cold launch the roster lands before the first
            // layout pass, so wait for the measurement rather than flying from
            // `.zero`. Bounded, because a target that never appears (it was
            // retired, it finished) must not leave a task waiting forever.
            for _ in 0..<8 where titleFrames[target] == nil {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard open == nil, sheetKind == nil, !locked,
                  fleet[target]?.isBlocked == true else { return }
            enter(target)
        }
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

    func leave() {
        if let open { backedOutAt[open] = .now }
        fleet.foreground(nil)
        closeMap()
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
        guard !locked else { return }
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
            if target == 0 {
                if let open { backedOutAt[open] = .now }
                fleet.foreground(nil)
                closeMap()
            }
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
                    onDismiss: { dismissSheet() },
                    onDispatch: { dispatch(agent, $0) },
                    onRetask: { text, stopFirst in retask(agent, text, stopFirst) },
                    onKill: { killWithCard(agent) },
                    onRetire: { retire(agent, $0) },
                    onPurge: { present(.purge(agent.name, nil)) },
                    onDrag: slide)
            }
        case .brief:
            BriefSheet(capability: fleet.globalControls.first { $0.id == "new" },
                       progress: sheet, busy: busyControl != nil,
                       onDismiss: { dismissSheet() }, onSend: brief(task:), onDrag: slide)
        case .purge(let id, let beforeSeq):
            if let agent = fleet[id] {
                PurgeSheet(agent: agent, progress: sheet, beforeSeq: beforeSeq,
                           onDismiss: { dismissSheet() }, onDrag: slide,
                           dryRun: { scope, before in
                               await fleet.dryRun(id, scope: scope, beforeSeq: before)
                           },
                           commit: { scope, before, counts in
                               purge(agent, scope: scope, beforeSeq: before, counts: counts)
                           })
            }
        }
    }

    private func present(_ kind: SheetKind) {
        guard !locked else { return }
        sheetKind = kind
        withAnimation(.glide) { sheet = 1 }
    }

    // MARK: - The map
    //
    // The same mechanism as `nav`, its own scalar. Five scrubbable seams in the
    // app share one shape; the slam card is deliberately outside it (§9.2).

    private func slideMap(_ phase: SheetPhase) {
        guard !locked else { return }
        switch phase {
        case .move(let progress):
            // Opens as soon as it is peeking rather than at the commit, so the
            // panel is never a blank rectangle sliding down.
            if progress > 0.04 { mapOpen = true }
            map = progress
        case .release(let velocityPerSecond):
            let predicted = map + project(velocityPerSecond)
            let target: Double = predicted < 0.42 ? 0 : 1
            let distance = target - map
            let v0 = abs(distance) < 1e-4 ? 0 : velocityPerSecond / distance
            withAnimation(.interpolatingSpring(mass: 1,
                                               stiffness: target == 0 ? 300 : 220,
                                               damping: target == 0 ? 34 : 30,
                                               initialVelocity: v0),
                          completionCriteria: .removed) {
                map = target
            } completion: {
                // Torn down 440 ms after the panel has left, not on release.
                if map == 0 {
                    Task {
                        try? await Task.sleep(for: .milliseconds(440))
                        if map == 0 { mapOpen = false }
                    }
                }
            }
        }
    }

    private func closeMap() {
        guard mapOpen else { return }
        withAnimation(.navBack) { map = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if map == 0 { mapOpen = false }
        }
    }

    // MARK: - The news (APP-PLAN 4.6, beat 980)

    /// **The one thing the merge adds.** Prime assumes he is looking at the
    /// list, Telemetry assumes he is not; both are true at different times, so
    /// the beat branches on which layer is visible rather than one concept
    /// winning outright.
    private func deliverNews() {
        guard let news = fleet.news else { return }
        fleet.takeNews()
        let onFleet = nav < 0.5 && sheetKind == nil && map < 0.5
        if onFleet {
            toast = Toast(text: "\(news.agent) is blocked — pinned above the fleet")
        } else {
            signal = Signal(id: news.id, agent: news.agent, question: news.question,
                            since: fleet[news.agent]?.blockedAt ?? news.at)
        }
    }

    private func openSignal() {
        guard let target = signal?.agent else { return }
        signal = nil
        guard !locked else { return }
        if open == target { return }
        if open != nil { leave() }
        // The same transition a tap runs.
        enter(target)
    }

    // MARK: - Retention

    private func retire(_ agent: Agent, _ retired: Bool) {
        guard busyControl == nil else { return }
        busyControl = "retire"
        Task {
            defer { busyControl = nil }
            switch await fleet.retire(agent.name, retired) {
            case .ok(let result):
                toast = Toast(text: result.retired
                              ? "Retired — it moved to the retired section."
                              : "Back in the fleet.")
            case .failed(let why):
                toast = Toast(text: why)
            }
        }
    }

    /// `drawer` is the slam card's own pre-roll: the sheet slides down over
    /// 440 ms on `ease-drawer` while the card is already on its way, rather than
    /// on the springs the rest of the app leaves a sheet with. The card is the
    /// one part of this app that is not spring-driven, and its pre-roll has to
    /// match it or the two read as separate events.
    func dismissSheet(drawer: Bool = false) {
        withAnimation(drawer ? .timingCurve(0.32, 0.72, 0, 1, duration: 0.44) : .navBack,
                      completionCriteria: .removed) {
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
