import Foundation

// The map's data layer, and it imports Foundation only on purpose: this is the
// part of step 8 that can be executed on the box the app is built on
// (`app/wiretest/run.sh`), and the two things most likely to be quietly wrong --
// phase nesting and the scrub/timeline arbitration -- are both here rather than
// in a view.

// MARK: - Where the route actually comes from

/// One leg of the route.
///
/// **The server does not send phase records on `/agents/history`.** APP-PLAN 6.2
/// says "phases from `POST /agents/history`'s phase records" and SERVER-PLAN §6's
/// response column for that endpoint is `{events, oldest_seq, newest_seq,
/// has_more}` -- there is no `phases` key in either the contract or the deployed
/// daemon's reply, verified against `100.72.2.62:8789` on 2026-08-26. The daemon
/// does keep a `phases` table, and nothing serves it.
///
/// What it *does* send is the route inline in the event stream: a `phase` event
/// carrying the title and the leg's id, an `outcome` event carrying the closing
/// line and the same id, and every `tool` and `compact` row tagged with the id of
/// the leg that was running. That is strictly more than a phase record -- it is
/// the nesting as well -- so the route is reconstructed from it here, and
/// `HistoryPage.phases` is still honoured if a later daemon starts sending it.
nonisolated struct RoutePhase: Identifiable, Sendable, Hashable {
    let id: String
    /// **`nil` when the opening event is not in the loaded history.** A page that
    /// starts mid-leg has the tool calls but not the title, and there is no
    /// honest way to name it. The row says so rather than inventing one.
    let title: String?
    let outcome: String?
    let startedAt: Date
    let endedAt: Date?
    /// `startedAt` is the first tool call's timestamp, not the leg's real start,
    /// because the opening event was never loaded. It is a lower bound.
    let startInferred: Bool
    /// Tool calls, compactions included, in the order the store handed them out.
    let tools: [Moment]

    var isOpen: Bool { endedAt == nil }
    var ended: Date? { endedAt }

    /// `nil` while it is still running: a leg with no end has no duration, and
    /// measuring it to "now" would make a number that changes when nothing did.
    var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// The whole route, plus the two things it could not place.
nonisolated struct Route: Sendable, Equatable {
    var phases: [RoutePhase] = []
    /// Tool calls the server could not attribute to a leg. **Named, never
    /// filed into a phantom bucket** -- SERVER-PLAN §2 drops unattributable
    /// events loudly on its side and this is the same rule on ours.
    var unphased: [Moment] = []
    /// `compact_boundary` rows, which are also in their phase's `tools`. They
    /// are listed separately because the recorder marks them on the waveform,
    /// which is the one place the context history exists as two real points
    /// either side of a boundary.
    var compactions: [Moment] = []

    var isEmpty: Bool { phases.isEmpty && unphased.isEmpty }

    /// Every phase boundary, in seconds since `from`. What the scrub snaps to.
    func boundaries(since from: Date) -> [TimeInterval] {
        var out: [TimeInterval] = []
        for phase in phases {
            out.append(phase.startedAt.timeIntervalSince(from))
            if let end = phase.endedAt { out.append(end.timeIntervalSince(from)) }
        }
        return out.sorted()
    }

    /// Where a leg stops on the strip.
    ///
    /// A leg that was never closed by an outcome row is still over once the next
    /// one opens -- SERVER-PLAN §2's boundary rule is "the next real user turn or
    /// Stop", and a page that lost the outcome row must not draw one leg across
    /// all the ones after it. Only the *last* leg is genuinely open-ended, and
    /// `nil` says so rather than defaulting it to now.
    func end(of index: Int) -> Date? {
        guard phases.indices.contains(index) else { return nil }
        if let closed = phases[index].endedAt { return closed }
        let next = index + 1
        return phases.indices.contains(next) ? phases[next].startedAt : nil
    }

    /// Which leg covers an instant. `nil` in the gaps between legs, which are
    /// real: an agent is not always inside a phase.
    func phase(at instant: Date) -> RoutePhase? {
        for index in phases.indices.reversed() {
            let leg = phases[index]
            guard leg.startedAt <= instant else { continue }
            guard let stop = end(of: index) else { return leg }   // still running
            if stop >= instant { return leg }
            return nil                                            // it is in the gap after this leg
        }
        return nil
    }
}

/// Rebuild the route from one channel's events.
///
/// `declared` is `HistoryPage.phases` when a daemon sends it: those records win
/// on title, outcome and times, because they are the store's own row rather
/// than a reconstruction. The nesting still comes from the events either way,
/// since a phase record does not carry its tool calls.
nonisolated func route(from moments: [Moment], declared: [Phase] = []) -> Route {
    struct Leg {
        var title: String?
        var outcome: String?
        var startedAt: Date
        var endedAt: Date?
        var startInferred: Bool
        var tools: [Moment] = []
    }

    var legs: [String: Leg] = [:]
    var order: [String] = []
    var out = Route()

    for record in declared {
        legs[record.id] = Leg(title: record.title, outcome: record.outcome,
                              startedAt: Date(timeIntervalSince1970: record.startedAt),
                              endedAt: record.endedAt.map { Date(timeIntervalSince1970: $0) },
                              startInferred: false)
        order.append(record.id)
    }

    for moment in moments.sorted(by: { $0.seq < $1.seq }) {
        // A phase or outcome row with no id cannot be placed. It is not a leg
        // and it is not a tool call; the thread still shows it.
        guard let id = moment.phase else {
            if moment.kind == .tool || moment.kind == .compact { out.unphased.append(moment) }
            if moment.kind == .compact { out.compactions.append(moment) }
            continue
        }
        if legs[id] == nil {
            // Created by whatever mentioned it first. If that was a tool call,
            // the leg has no title and says so.
            legs[id] = Leg(title: nil, outcome: nil, startedAt: moment.at,
                           endedAt: nil, startInferred: moment.kind != .phase)
            order.append(id)
        }
        switch moment.kind {
        case .phase:
            // The opening event is authoritative for both, even when a tool
            // call created the leg first -- which is what a page boundary
            // landing between them looks like.
            legs[id]?.title = moment.text
            legs[id]?.startedAt = moment.at
            legs[id]?.startInferred = false
        case .outcome:
            // An empty outcome is the server saying it had nothing to quote,
            // not an outcome of "".
            legs[id]?.outcome = moment.text.isEmpty ? nil : moment.text
            legs[id]?.endedAt = moment.at
        case .tool, .compact:
            legs[id]?.tools.append(moment)
            if moment.kind == .compact { out.compactions.append(moment) }
        case .you, .claude, .summary, .state, .error:
            break
        }
    }

    out.phases = order.compactMap { id in
        guard let leg = legs[id] else { return nil }
        return RoutePhase(id: id, title: leg.title, outcome: leg.outcome,
                          startedAt: leg.startedAt, endedAt: leg.endedAt,
                          startInferred: leg.startInferred, tools: leg.tools)
    }
    .sorted { $0.startedAt < $1.startedAt }

    return out
}

// MARK: - Scrub <-> timeline, as one value seen twice

/// APP-PLAN 6.3's `Driver`.
///
/// The failure mode this exists to prevent is a feedback loop: the strip drives
/// the list, the list drives the strip, and they oscillate. The prototype breaks
/// it with a "quiet" write -- a flag somebody has to remember to clear. Here the
/// invalid combination is unspellable: **whichever surface a finger is on owns
/// the cursor, and the other one's write is refused until the gesture ends.**
nonisolated struct Playhead: Sendable, Equatable {
    nonisolated enum Driver: Sendable, Equatable {
        case strip, timeline, neither
    }

    private(set) var cursor: TimeInterval = 0
    private(set) var driver: Driver = .neither

    init(cursor: TimeInterval = 0) { self.cursor = cursor }

    /// The strip's gesture. Refused while the timeline is the one being dragged.
    mutating func scrub(to seconds: TimeInterval) {
        guard driver != .timeline else { return }
        driver = .strip
        cursor = seconds
    }

    /// The timeline's scroll observer. Refused while the strip owns the cursor.
    mutating func follow(_ seconds: TimeInterval) {
        guard driver != .strip else { return }
        driver = .timeline
        cursor = seconds
    }

    /// A write neither surface is driving -- the initial position, or a snap
    /// applied after the finger has already lifted.
    mutating func place(_ seconds: TimeInterval) {
        guard driver == .neither else { return }
        cursor = seconds
    }

    mutating func release() { driver = .neither }
}

/// The phase boundary a throw should land on, if it is close enough.
///
/// Within 4.5 % of the session's span, per APP-PLAN 6.3. `nil` means the throw
/// was not aimed at a boundary and should be left exactly where it stopped --
/// snapping everything would make the strip impossible to park mid-phase.
nonisolated func snapped(_ seconds: TimeInterval, to boundaries: [TimeInterval],
                         span: TimeInterval, tolerance: Double = 0.045) -> TimeInterval? {
    guard span > 0 else { return nil }
    let reach = span * tolerance
    var best: TimeInterval?
    var bestGap = Double.greatestFiniteMagnitude
    for boundary in boundaries {
        let gap = abs(boundary - seconds)
        if gap <= reach, gap < bestGap {
            best = boundary
            bestGap = gap
        }
    }
    return best
}

// MARK: - Tool ticks

/// APP-PLAN 6.3's tick colours, as five buckets rather than four.
///
/// **A four-way classification of an open-ended tool namespace would silently
/// mislabel every MCP tool.** The fifth bucket admits it does not know, and the
/// key on the strip says `other`, which is the honest version.
nonisolated enum ToolTick: String, Sendable, Hashable, CaseIterable {
    case read, edit, shell, signal, other

    var key: String {
        switch self {
        case .read: "read"
        case .edit: "write"
        case .shell: "shell"
        case .signal: "delegate"
        case .other: "other"
        }
    }
}

nonisolated func toolTick(_ moment: Moment) -> ToolTick {
    // A ring's question and his answer are the block events the plan colours
    // `sig` alongside delegation: both are the agent leaving its own thread.
    if moment.kind == .you || moment.kind == .claude { return .signal }
    switch moment.tool {
    case "Read", "Grep", "Glob": return .read
    case "Edit", "Write", "NotebookEdit", "MultiEdit": return .edit
    case "Bash", "BashOutput", "KillShell": return .shell
    case "Task", "Agent", "SendMessage": return .signal
    default: return .other
    }
}
