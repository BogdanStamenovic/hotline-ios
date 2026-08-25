import Foundation

/// The roster, and the one place that decides display order.
///
/// `@Observable` rather than `ObservableObject`: SwiftUI then tracks exactly
/// the properties each view reads, so the header's counts changing does not
/// invalidate every row.
///
/// Step 0 has no network at all. `apply(roster:)` is the seam the roster stream
/// will write through, and it exists now so that display order is decided in
/// one place from the beginning rather than being retrofitted around a stream.
@Observable
final class Fleet {
    /// Roster order, exactly as the server gave it.
    private(set) var agents: [Agent] = []
    /// Display order: blocked pinned to the top, then roster order. Retired
    /// agents are not in here -- they belong to their own section (step 10).
    private(set) var order: [AgentID] = []
    /// `new`, for pull-up-past-the-bottom. Server-declared; empty renders as
    /// "not offered", never as a guessed control.
    private(set) var globalControls: [Capability] = []

    private var byID: [AgentID: Agent] = [:]

    subscript(id: AgentID) -> Agent? { byID[id] }

    var blockedCount: Int { agents.filter(\.isBlocked).count }
    var liveCount: Int { agents.filter { $0.presence != .dead }.count }

    /// The single reconciliation point. Everything that changes the roster
    /// goes through here, so display order is decided once and cannot drift
    /// between callers.
    func apply(roster: [Agent]) {
        let visible = roster.filter { !$0.isRetired }
        agents = visible
        byID = Dictionary(visible.map { ($0.name, $0) }, uniquingKeysWith: { _, b in b })
        // A stable partition, not a sort: within each half the server's order
        // is preserved, so a roster that has not changed cannot reshuffle.
        order = visible.filter(\.isBlocked).map(\.name)
            + visible.filter { !$0.isBlocked }.map(\.name)
    }
}

/// The roster step 0 is judged against, in the shape `/api/v1/agents` returns.
///
/// It is here so the list can be held up on a real screen at real brightness
/// before a single byte of network code exists -- density, type and the dot's
/// four states are decided by looking, not by reading. Deleted in step 1.
enum Fixture {
    static let roster: [Agent] = [
        Agent(name: "hotline-80", task: "reply-waiter and the remaining open items",
              cwd: "/home/bodas/data/hotline", live: true, busy: false,
              state: .idle, deadReason: nil, stalled: false,
              lastToolAt: Date.now.addingTimeInterval(-260).timeIntervalSince1970,
              blocked: true, blockedSince: Date.now.addingTimeInterval(-252).timeIntervalSince1970,
              retired: false, historyGeneration: 3, declaredAt: nil,
              contextAvailable: true, vitals: nil, controls: nil),
        Agent(name: "hotline-ios", task: "building the hotline iOS app",
              cwd: "/home/bodas/data/hotline-ios", live: true, busy: true,
              state: .working, deadReason: nil, stalled: false,
              lastToolAt: Date.now.addingTimeInterval(-9).timeIntervalSince1970,
              blocked: false, blockedSince: nil, retired: false,
              historyGeneration: 11, declaredAt: nil, contextAvailable: true,
              vitals: nil, controls: nil),
        Agent(name: "data-89", task: "B was the plan either way — do whichever is free",
              cwd: "/home/bodas/data", live: true, busy: false,
              state: .idle, deadReason: nil, stalled: false,
              lastToolAt: Date.now.addingTimeInterval(-3400).timeIntervalSince1970,
              blocked: false, blockedSince: nil, retired: false,
              historyGeneration: 0, declaredAt: nil, contextAvailable: true,
              vitals: nil, controls: nil),
        Agent(name: "data-75", task: "RDP access to archserver from the other arch box",
              cwd: "", live: false, busy: false,
              state: .dead, deadReason: "its process is gone and it never said done",
              stalled: false, lastToolAt: Date.now.addingTimeInterval(-97_000).timeIntervalSince1970,
              blocked: false, blockedSince: nil, retired: false,
              historyGeneration: 0, declaredAt: nil, contextAvailable: false,
              vitals: nil, controls: nil),
    ]
}
