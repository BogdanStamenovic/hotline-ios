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
    /// Set once, when the daemon answers 404. The deployed build predates
    /// `roster-events`; without this the app would either hammer a missing
    /// endpoint or go silent, and neither is what "the list stays true" means.
    private var tickEndpointMissing = false

    init(link: Link) { self.link = link }

    subscript(id: AgentID) -> Agent? { byID[id] }

    var blockedCount: Int { agents.filter(\.isBlocked).count }
    var liveCount: Int { agents.filter { $0.presence != .dead }.count }

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
        let visible = roster.filter { !$0.isRetired }
        agents = visible
        byID = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        // A stable partition, not a sort: within each half the server's order
        // is preserved, so a roster that has not changed cannot reshuffle.
        order = visible.filter(\.isBlocked).map(\.name)
            + visible.filter { !$0.isBlocked }.map(\.name)
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
