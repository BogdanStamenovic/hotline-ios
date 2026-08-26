import Foundation
import OSLog
import SwiftUI

/// Whether what is on screen is what is on archserver.
enum Reachability: Equatable, Sendable {
    case unknown
    case live
    /// `since` is when the roster was last known good -- not when the failure
    /// happened. That is the number he needs: a banner that says "3 s ago" for
    /// a request that has been retrying for four minutes is a lie about the
    /// data, not about the network.
    ///
    /// `nil` means there has never been a good roster, which is a different
    /// screen: nothing on it is stale because nothing on it is anything.
    case stale(since: Date?, why: String)
}

/// The roster, the roster stream, and the one place that decides display order.
///
/// `@Observable` rather than `ObservableObject`: SwiftUI then tracks exactly
/// the properties each view reads, so the header's counts changing does not
/// invalidate every row.
///
/// **`Fleet` owns the roster stream and nothing else in the app owns a network
/// task except a `Channel`** (step 4). The invariant, stated so it can be
/// checked in review: the only thing that starts or stops the roster stream is
/// the app becoming, or ceasing to be, active.
@Observable
final class Fleet {
    /// Roster order, exactly as the server gave it.
    private(set) var agents: [Agent] = []
    /// Display order: blocked pinned to the top, then roster order. Retired
    /// agents are not in here -- they belong to their own section (8.1).
    ///
    /// **It is deliberately not written at the same instant as `agents`.** When
    /// an agent blocks, the dot has to change at t = 0 and the row has to climb
    /// at t = 320 (APP-PLAN 4.6); writing both together collapses the two beats
    /// into one and the overtake -- which is the whole point of the
    /// choreography -- never happens.
    private(set) var order: [AgentID] = []
    /// Retired agents, in roster order. They keep their live dot: retirement is
    /// visibility only and one of these may still be running.
    private(set) var retired: [Agent] = []
    /// `new`, from `/health`. Empty until server step 8 declares it, and an
    /// empty list renders as "not offered", never as a guessed control.
    private(set) var globalControls: [Capability] = []
    private(set) var reachable: Reachability = .unknown
    /// When the roster on screen was last true.
    private(set) var freshAt: Date?

    /// The long-poll's wait, in seconds. **5 while a channel is open, 25
    /// otherwise.** Not a performance tweak: it is the refresh rate of the
    /// in-channel instrument strip and the only knob that decides whether the
    /// readouts feel live. On the fleet list nothing is sampled, so the long
    /// wait is correct there and costs nothing.
    static let sampleWait: Double = 5
    static let idleWait: Double = 25

    // MARK: - The arrival choreography (APP-PLAN 4.6, driven in `Arrival.swift`)

    /// What the header's counts say. Written at the 820 ms beat during an
    /// arrival and immediately otherwise, so the numbers catch up *after* the
    /// row has said what happened rather than at the same instant.
    private(set) var counts = Counts()
    /// Per-agent beat progress. Absent means quiet, which is the common case.
    private(set) var beats: [AgentID: ArrivalBeats] = [:]
    /// The header's accent rule: 0...1 sweeping in from the left, 1...2
    /// collapsing to the right. One value, so the anchor flip cannot desync
    /// from the scale.
    private(set) var sweep: Double = 0
    /// The row that is climbing. It gets `climb`; everything else gets `float`
    /// with a delay that propagates outward from it. **The pair is load-bearing
    /// and must not be collapsed into one spring** -- watching the row jump the
    /// queue rather than the queue tidily re-sorting is the whole point.
    private(set) var mover: AgentID?
    /// The 980 ms beat, for whichever surface is visible.
    private(set) var news: Arrival?
    /// Bumped once per arrival, for `Shell`'s single `.sensoryFeedback`.
    private(set) var pulse = 0
    /// Pushed in by `Shell`, which is the only thing that can read the
    /// environment. The sequence survives; the durations compress.
    var reduceMotion = false

    private var blockedFlags: [AgentID: Bool] = [:]
    private var owed: [Arrival] = []
    private var choreography: Task<Void, Never>?
    private var arrivalsHeld = false
    /// True between a detected block change and its t = 320 beat. `apply` will
    /// not touch `order` while it is set, which is what keeps the dot's beat and
    /// the climb 320 ms apart instead of in the same frame.
    private var orderHeld = false
    private var questionsMissing = false

    private let link: Link
    private let log = Logger(subsystem: "dev.stamenovic.hotline", category: "fleet")
    private var byID: [AgentID: Agent] = [:]
    private var stream: Task<Void, Never>?
    private var cursor = 0
    private var foregroundAgent: AgentID?
    /// One `Channel` per agent, created lazily and never twice. This map is the
    /// only place a channel lives, which is what leaves no shared transcript
    /// array for bug 2 to leak through.
    private var channels: [AgentID: Channel] = [:]
    /// The last `historyGeneration` seen per agent, so a change can be noticed.
    private var generations: [AgentID: Int] = [:]
    private let cache = Cache()
    /// Set once, when the daemon answers 404. The deployed build predates
    /// `roster-events`; without this the app would either hammer a missing
    /// endpoint or go silent, and neither is what "the list stays true" means.
    private var tickEndpointMissing = false

    init(link: Link) { self.link = link }

    subscript(id: AgentID) -> Agent? { byID[id] ?? retired.first { $0.name == id } }

    var blockedCount: Int { agents.filter(\.isBlocked).count }
    var liveCount: Int { agents.filter { $0.presence == .live || $0.presence == .busy || $0.presence == .blocked }.count }

    /// The question a blocked agent is waiting on, when the daemon holds one.
    ///
    /// The roster does not carry it -- a ring opens the conversation
    /// server-side -- so it comes from `/api/v1/conversations`, which
    /// SERVER-PLAN §6's table omits and which is the only way to answer a
    /// blocked agent at all. An agent with no open conversation has no question,
    /// and the row keeps saying what it was told to do rather than inventing one.
    private(set) var questions: [AgentID: String] = [:]

    /// Which channel is open, if any. Nothing else reads it -- it exists to
    /// pick the long-poll's wait.
    func foreground(_ id: AgentID?) {
        let wasOpen = foregroundAgent != nil
        foregroundAgent = id
        // The wait is chosen when the request is made, so a channel opening
        // while the stream is parked in a 25 s poll would not sample for up to
        // 25 s -- long enough to read as a dead instrument strip. Restarting
        // costs one request and loses nothing: the cursor lives here, not in
        // the task.
        if wasOpen != (id != nil), stream != nil {
            suspend()
            begin()
        }
    }

    private var waitSeconds: Double {
        foregroundAgent == nil ? Self.idleWait : Self.sampleWait
    }

    // MARK: - The stream

    func begin() {
        guard stream == nil else { return }
        stream = Task { [weak self] in await self?.run() }
    }

    func suspend() {
        stream?.cancel()
        stream = nil
    }

    /// The launch refresh, and the one a pull past the top runs. Separate from
    /// the stream because it must land before the first frame of the list is
    /// judged, and because a pull is a request for *now*, not for the next
    /// tick.
    func hardRefresh() async {
        do {
            // `include_done` and `include_retired` are both on: a finished agent
            // has its own dot (APP-PLAN 12.5) and a retired one has its own
            // section (8.1), and neither can be rendered by a client that never
            // asked for it.
            let roster = try await link.agents(includeDone: true, includeRetired: true)
            apply(roster: roster)
            markLive()
        } catch {
            markStale(error)
        }
        await refreshQuestions()
        // Independent of the roster: /health carries `globalControls`, and a
        // roster that arrived while health failed is still worth showing.
        do {
            let health = try await link.health()
            globalControls = health.globalControls ?? []
        } catch {
            log.error("health: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func run() async {
        var backoff = Duration.milliseconds(250)
        while !Task.isCancelled {
            do {
                try await tick()
                let roster = try await link.agents(includeDone: true, includeRetired: true)
                apply(roster: roster)
                markLive()
                backoff = .milliseconds(250)
            } catch is CancellationError {
                break
            } catch {
                if Task.isCancelled { break }
                markStale(error)
                log.error("roster: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(5))
            }
        }
    }

    /// Block until the roster stops being true, or until the wait is up.
    ///
    /// Against a daemon that has not shipped `roster-events` this degrades to
    /// sleeping for the same interval and refetching -- the same cadence, one
    /// wasted request per wake, and no lost liveness. The endpoint is probed
    /// once and never again.
    private func tick() async throws {
        guard !tickEndpointMissing else {
            try await Task.sleep(for: .seconds(waitSeconds))
            return
        }
        do {
            let tick = try await link.rosterEvents(since: cursor, wait: waitSeconds)
            cursor = max(cursor, tick.cursor)
        } catch let failure as Link.Failure where failure.isMissingEndpoint {
            tickEndpointMissing = true
            log.notice("archserver has no roster-events; falling back to a timed refetch")
            try await Task.sleep(for: .seconds(waitSeconds))
        }
    }

    // MARK: - Reconciliation

    /// The single reconciliation point. Everything that changes the roster --
    /// a hard refresh, a roster tick, a seeded fixture -- goes through here, so
    /// display order is decided once and cannot drift between callers.
    func apply(roster: [Agent]) {
        // **Before anything else touches a channel** (APP-PLAN 8.4). A purge
        // from anywhere -- another client, the CLI, a script -- reaches the
        // phone as a generation that no longer matches, and the whole local
        // copy for that agent goes. No explicit invalidation protocol, and no
        // client-side gap detection: with one global `seq`, a hole is either
        // another agent's events or a purge, and this is the purge case.
        for agent in roster {
            let next = agent.generation
            defer { generations[agent.name] = next }
            guard let known = generations[agent.name], known != next else { continue }
            if let channel = channels[agent.name] {
                channel.invalidate(generation: next)
            } else {
                Task { [cache] in await cache.drop(agent.name) }
            }
        }

        // Before the display order moves, so the beat that moves it can hold it
        // back for 320 ms (APP-PLAN 4.6). Nothing else in the app writes `order`.
        noteBlockChanges(roster)

        let visible = roster.filter { !$0.isRetired }
        agents = visible
        retired = roster.filter(\.isRetired)
        byID = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        if !orderHeld { reorder() }
        if choreography == nil { counts = Counts(total: agents.count, blocked: blockedCount) }

        // One reading per roster wake, into the open channel only. There is no
        // fleet-wide sample store because there is no fleet-wide readout
        // (APP-PLAN 5.0), and a `Vitals` that is absent appends nothing rather
        // than a zero.
        if let open = foregroundAgent, let agent = byID[open] {
            channels[open]?.sample(agent.vitals)
        }
    }

    /// A stable partition, not a sort: within each half the server's order is
    /// preserved, so a roster that has not changed cannot reshuffle.
    private func reorder() {
        orderHeld = false
        order = agents.filter(\.isBlocked).map(\.name)
            + agents.filter { !$0.isBlocked }.map(\.name)
    }

    // MARK: - The arrival choreography (APP-PLAN 4.6)

    /// **No arrival choreography runs while the slam card holds the lock.**
    /// It is queued, not dropped: a card covering the screen for two seconds
    /// must not swallow the one notification the app exists to deliver.
    func holdChoreography() { arrivalsHeld = true }

    func releaseChoreography() {
        arrivalsHeld = false
        drainArrivals()
    }

    func takeNews() { news = nil }

    /// Only a real false -> true (or true -> false) transition counts. A roster
    /// that repeats an agent's blocked state -- which is every tick while he is
    /// thinking about it -- fires nothing. An agent this app has never seen
    /// before does not fire either: arriving already-blocked is not news
    /// travelling, it is just what the list says.
    private func noteBlockChanges(_ roster: [Agent]) {
        var found: [Arrival] = []
        for agent in roster where !agent.isRetired {
            let was = blockedFlags[agent.name]
            blockedFlags[agent.name] = agent.isBlocked
            guard let was, was != agent.isBlocked else { continue }
            found.append(Arrival(agent: agent.name, unblocking: !agent.isBlocked,
                                 at: .now, question: questions[agent.name]))
        }
        let alive = Set(roster.map(\.name))
        blockedFlags = blockedFlags.filter { alive.contains($0.key) }
        guard !found.isEmpty else { return }
        owed += found
        orderHeld = true
        drainArrivals()
    }

    private func drainArrivals() {
        guard !arrivalsHeld, choreography == nil, !owed.isEmpty else {
            // Nothing is going to move the order at a beat, so it must not be
            // left frozen either.
            if owed.isEmpty, choreography == nil, orderHeld { reorder() }
            return
        }
        let next = owed.removeFirst()
        choreography = Task { [weak self] in
            await self?.perform(next)
            guard let self else { return }
            choreography = nil
            drainArrivals()
        }
    }

    /// The six beats, in order, with one sleep between each.
    ///
    /// Under Reduce Motion the **sequence survives** and the durations compress:
    /// the beats depend on each other's state, and firing them in one tick makes
    /// the sequence read wrong as well as look wrong (APP-PLAN 4.9).
    private func perform(_ arrival: Arrival) async {
        let name = arrival.agent
        let out = arrival.unblocking
        let mo = reduceMotion ? 0.38 : 1.0

        var news = arrival
        if !out {
            // One request, and only when something actually blocked. The roster
            // does not carry the question -- a ring opened the conversation
            // server-side -- so this is the only way to have one to show.
            await refreshQuestions()
            news.question = questions[name]
        }

        // ---- t = 0. The dot switches, the header rule sweeps, one pulse.
        pulse &+= 1
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.51 * mo)) { sweep = 1 }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(510 * mo)))
            guard let self else { return }
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.99 * mo)) { sweep = 2 }
            try? await Task.sleep(for: .milliseconds(Int(990 * mo)))
            sweep = 0
        }

        // ---- t = 140. The row says it in words.
        try? await beat(140, mo)
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.42 * mo)) {
            beats[name, default: ArrivalBeats()].words = out ? 0 : 1
        }

        // ---- t = 320. The row becomes the thing it is. And it climbs.
        try? await beat(180, mo)
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: (out ? 0.30 : 0.64) * mo)) {
            beats[name, default: ArrivalBeats()].wash = out ? 0 : 1
        }
        beats[name, default: ArrivalBeats()].lifted = true
        withAnimation(.enter) { beats[name, default: ArrivalBeats()].lift = 1 }
        mover = name
        reorder()

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(500 * mo)))
            guard let self else { return }
            withAnimation(.settle) { beats[name, default: ArrivalBeats()].lift = 0 }
            try? await Task.sleep(for: .milliseconds(Int(360 * mo)))
            beats[name]?.lifted = false
            if mover == name { mover = nil }
            if beats[name]?.isQuiet == true { beats[name] = nil }
        }

        // ---- t = 820. The fleet counts catch up, by blur-crossfade.
        try? await beat(500, mo)
        counts = Counts(total: agents.count, blocked: blockedCount)

        // ---- t = 980. The news finds him. Which surface it lands on is
        // `Shell`'s call, because only `Shell` knows which layer is visible.
        try? await beat(160, mo)
        if !out { self.news = news }
    }

    private func beat(_ milliseconds: Int, _ mo: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(Double(milliseconds) * mo)))
    }

    /// The open questions, by agent. `/api/v1/conversations` is missing from
    /// SERVER-PLAN §6's endpoint table and is nonetheless the only way to learn
    /// what a ring asked, because the ring opened the conversation on the server
    /// and the phone was never told its id. Probed once, like every other
    /// endpoint this daemon might not have.
    func refreshQuestions() async {
        guard !questionsMissing else { return }
        do {
            let open = try await link.conversations()
            var found: [AgentID: String] = [:]
            for conversation in open where conversation.isOpen {
                guard let agent = conversation.agent, let asked = conversation.asked,
                      !asked.isEmpty, found[agent] == nil else { continue }
                found[agent] = asked
            }
            questions = found
        } catch let failure as Link.Failure where failure.isMissingEndpoint {
            questionsMissing = true
        } catch {
            // Not fatal and not worth a banner: without it the row keeps saying
            // what the agent was told to do, which is true and less specific.
            log.notice("conversations: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What the header's counts say, held back to the 820 ms beat.
    nonisolated struct Counts: Equatable, Sendable {
        var total = 0
        var blocked = 0
    }

    // MARK: - Channels

    /// The only way to get a channel. Lazily created, kept for the session, so
    /// re-opening one is a plain array read rather than a disk hop.
    func channel(for id: AgentID) -> Channel {
        if let existing = channels[id] { return existing }
        let made = Channel(name: id, link: link, cache: cache)
        channels[id] = made
        return made
    }

    /// Start the cache read at the instant the row is tapped, so it is already
    /// in flight while the scene change plays.
    func warm(_ id: AgentID) {
        let channel = channel(for: id)
        let generation = byID[id]?.generation ?? 0
        Task { await channel.prime(rosterGeneration: generation) }
    }

    // MARK: - Control dispatch
    //
    // The app hardcodes the endpoint and body shape for each `id` it knows how
    // to send -- an ordinary client/server contract. It hardcodes nothing about
    // which capabilities exist, their order, their label, their enabled state
    // or their reason: all of that is `Agent.controls`, rendered as it arrives.
    //
    // Server-side enforcement is independent of the declaration. `/agents/stop`
    // returns 409 on its own even against a stale client, and a 409 is rendered
    // as its message rather than as a generic failure -- which is why every
    // failure path here carries `Link.Failure`'s own words.

    /// What a control did. Both arms carry a sentence, because "it worked" and
    /// "it did not" are equally worth saying out loud when the thing being
    /// controlled is a process on another machine.
    enum Attempt<Value: Sendable>: Sendable {
        case ok(Value)
        case failed(String)
    }

    func stop(_ agent: AgentID) async -> Attempt<StopResult> {
        await run { try await self.link.stop(agent: agent) }
    }

    func kill(_ agent: AgentID) async -> Attempt<KillResult> {
        await run { try await self.link.kill(agent: agent) }
    }

    /// One request, composed server-side: two calls from a phone means a
    /// dropped network can leave an agent cancelled with nothing queued.
    func retask(_ agent: AgentID, text: String, stopFirst: Bool,
                clientToken: String? = nil) async -> Attempt<RetaskResult> {
        await run {
            try await self.link.retask(agent: agent, text: text,
                                       stopFirst: stopFirst, clientToken: clientToken)
        }
    }

    func resume(_ agent: AgentID) async -> Attempt<ResumeResult> {
        await run { try await self.link.resume(agent: agent) }
    }

    func compact(_ agent: AgentID, then: String? = nil) async -> Attempt<CompactResult> {
        await run { try await self.link.compact(agent: agent, then: then) }
    }

    func brief(task: String) async -> Attempt<NewResult> {
        await run { try await self.link.new(task: task) }
    }

    // MARK: - Retention

    /// Visibility only, and reversible. No confirmation, because nothing is
    /// destroyed.
    func retire(_ agent: AgentID, _ retired: Bool) async -> Attempt<RetireResult> {
        await run { try await self.link.retire(agent: agent, retired: retired) }
    }

    /// The dry run. It never deletes, so it does not go through `run` and does
    /// not trigger a hard refresh -- it is a question, asked possibly several
    /// times while a sheet is open.
    func dryRun(_ agent: AgentID, scope: String, beforeSeq: Int?) async -> Attempt<PurgeCounts> {
        do {
            return .ok(try await link.purge(agent: agent, scope: scope,
                                            beforeSeq: beforeSeq, dryRun: true))
        } catch {
            return .failed((error as? LocalizedError)?.errorDescription
                           ?? error.localizedDescription)
        }
    }

    /// The destructive call.
    ///
    /// On success the local copy disappears **as a side effect of the real
    /// deletion succeeding**, never before it and never instead of it: the
    /// channel is invalidated with a bumped generation, which is the same path a
    /// purge from another client takes when the roster tells us about it.
    func purge(_ agent: AgentID, scope: String, beforeSeq: Int?) async -> Attempt<PurgeCounts> {
        let result = await run {
            try await self.link.purge(agent: agent, scope: scope,
                                      beforeSeq: beforeSeq, dryRun: false)
        }
        if case .ok = result {
            // The generation the *roster* now reports, not a locally invented
            // one: `run` has already hard-refreshed, so the server has told us
            // what the history's generation is. Making one up here would make
            // the next roster tick disagree and invalidate a second time.
            let now = byID[agent]?.generation ?? generations[agent] ?? 0
            channels[agent]?.invalidate(generation: now)
            if channels[agent] == nil { await cache.drop(agent) }
            if scope == "everything" { channels[agent] = nil }
        }
        return result
    }

    /// Settings' "free up space". Non-destructive on archserver, which is why it
    /// has no hold-to-fill and no slam card: it is not deletion.
    func freeUpSpace() async {
        await cache.dropEverything()
        for channel in channels.values { channel.invalidate(generation: channel.generation) }
    }

    func cacheBytes() async -> Int {
        await cache.bytes()
    }

    /// Whether any agent's session reports its context use. One sentence in
    /// Settings' diagnostics depends on it, and an absent gauge with no
    /// explanation is indistinguishable from a broken one.
    var contextReported: Bool {
        agents.contains { $0.contextAvailable == true }
    }

    /// Every dispatch ends with a hard refresh. The roster is what decides how
    /// the row and the state line read, and waiting up to a full roster wake to
    /// see the effect of a button makes the button feel broken even when it
    /// worked.
    private func run<Value: Sendable>(
        _ work: () async throws -> Value
    ) async -> Attempt<Value> {
        do {
            let value = try await work()
            await hardRefresh()
            return .ok(value)
        } catch {
            let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            log.error("control: \(why, privacy: .public)")
            return .failed(why)
        }
    }

    private func markLive() {
        freshAt = .now
        reachable = .live
    }

    /// Degrade at the network boundary: keep showing the last roster, and say
    /// how old it is. Going blank on a dropped tailnet would throw away the
    /// only useful thing the app still has.
    private func markStale(_ error: any Error) {
        let why = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if case .stale = reachable { return }   // don't reset the clock on a retry
        reachable = .stale(since: freshAt, why: why)
    }
}
