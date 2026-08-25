import Foundation
import OSLog

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
    /// agents are not in here -- they belong to their own section (step 10).
    private(set) var order: [AgentID] = []
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

    subscript(id: AgentID) -> Agent? { byID[id] }

    var blockedCount: Int { agents.filter(\.isBlocked).count }
    var liveCount: Int { agents.filter { $0.presence == .live || $0.presence == .busy || $0.presence == .blocked }.count }

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
            let roster = try await link.agents()
            apply(roster: roster)
            markLive()
        } catch {
            markStale(error)
        }
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
                let roster = try await link.agents()
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

        let visible = roster.filter { !$0.isRetired }
        agents = visible
        byID = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        // A stable partition, not a sort: within each half the server's order
        // is preserved, so a roster that has not changed cannot reshuffle.
        order = visible.filter(\.isBlocked).map(\.name)
            + visible.filter { !$0.isBlocked }.map(\.name)

        // One reading per roster wake, into the open channel only. There is no
        // fleet-wide sample store because there is no fleet-wide readout
        // (APP-PLAN 5.0), and a `Vitals` that is absent appends nothing rather
        // than a zero.
        if let open = foregroundAgent, let agent = byID[open] {
            channels[open]?.sample(agent.vitals)
        }
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
