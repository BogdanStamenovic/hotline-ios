import Foundation

// The module is main-actor-by-default (see Package.swift), which would make
// these types' synthesised Codable conformances main-actor-isolated too. They
// are decoded on `Link`, which is nonisolated, so the conformance has to be as
// well -- otherwise `JSONDecoder().decode` cannot see it from off the actor.
// This is also simply the truthful annotation: pure wire data, no UI state.
//
// Every field the daemon has not shipped yet is Optional, and every Optional
// gets `decodeIfPresent` from the synthesised initialiser. That is the whole
// forward-compatibility story: the app renders what is there and nothing else.
// It matters more here than it usually would -- a reinstall costs a 7-day
// provisioning profile, so a build has to survive the server moving under it.

typealias AgentID = String

// MARK: - Agent

/// A Claude Code session he can talk to, as hotline's registry knows it.
nonisolated struct Agent: Identifiable, Hashable, Sendable, Codable {
    let name: AgentID
    let task: String
    let cwd: String
    let live: Bool
    let busy: Bool

    // --- everything below is additive and may be absent ---

    let state: State?
    let deadReason: String?
    let stalled: Bool?
    let lastToolAt: Double?
    let blocked: Bool?
    let blockedSince: Double?
    let retired: Bool?
    let historyGeneration: Int?
    /// APP-PLAN 11's first ask: the strip's ELAPSED cell.
    let declaredAt: Double?
    /// APP-PLAN 5.6: distinguishes "no first turn yet" from "no statusLine
    /// wrapper installed". Those render identically without it and mean
    /// opposite things.
    let contextAvailable: Bool?
    let vitals: Vitals?
    /// Server-declared, never inferred. Absent until server step 8, and an
    /// absent list renders as no controls rather than a guessed one.
    let controls: [Capability]?

    var id: AgentID { name }

    /// What the daemon calls itself. Four states; the two that used to be
    /// indistinguishable -- a clean finish and a crash -- are the point.
    nonisolated enum State: String, Sendable, Hashable, Codable {
        case idle, working, done, dead
        /// A value this build has not been taught. Rendered as unknown rather
        /// than failing the whole roster decode over one string.
        case unrecognised

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = State(rawValue: raw) ?? .unrecognised
        }
    }

    /// The five appearances APP-PLAN 5.1's dot encodes.
    ///
    /// `done` and `dead` are separate on purpose (APP-PLAN 12.5). The daemon
    /// distinguishes an agent that finished and said so from one whose process
    /// is gone and never said anything; its own comments call that distinction
    /// the point, and collapsing them throws away a true fact at exactly the
    /// glance where it matters.
    nonisolated enum Presence: Sendable, Hashable {
        case live, busy, blocked, done, dead
    }

    var isBlocked: Bool { blocked ?? false }
    var isRetired: Bool { retired ?? false }
    var isStalled: Bool { stalled ?? false }
    var generation: Int { historyGeneration ?? 0 }
    var capabilities: [Capability] { controls ?? [] }

    var presence: Presence {
        Self.presence(state: state, blocked: isBlocked, live: live, busy: busy)
    }

    /// **The one place the daemon's vocabulary becomes an appearance.**
    ///
    /// The server says `idle | working | done | dead` with `blocked` as a
    /// separate boolean; the dot says `live | busy | blocked | done | dead`.
    /// Keeping the translation in a single named function is deliberate: the
    /// server's vocabulary has already moved once, and when it moves again this
    /// is one edit rather than a search.
    ///
    /// Blocked outranks everything, because it is the one thing he has to act
    /// on. The `nil` arm is the daemon that has not shipped `state` yet -- it
    /// sends only `live` and `busy`, and it cannot tell a clean finish from a
    /// crash, so it answers `.dead` for both. That is a narrower answer, not a
    /// wrong one: `done` requires a server that reports `done`.
    static func presence(state: State?, blocked: Bool, live: Bool, busy: Bool) -> Presence {
        if blocked { return .blocked }
        switch state {
        case .working: return .busy
        case .idle: return .live
        case .done: return .done
        case .dead: return .dead
        case .unrecognised, nil: return busy ? .busy : (live ? .live : .dead)
        }
    }

    var blockedAt: Date? { blockedSince.map { Date(timeIntervalSince1970: $0) } }
    var lastToolDate: Date? { lastToolAt.map { Date(timeIntervalSince1970: $0) } }
    var declaredDate: Date? { declaredAt.map { Date(timeIntervalSince1970: $0) } }

    /// What the row's right-hand column says. Nothing when the wire carries
    /// neither timestamp -- a fabricated "now" would be worse than a blank.
    var stamp: Date? { blockedAt ?? lastToolDate ?? declaredDate }
}

// MARK: - Vitals

/// The live block APP-PLAN 5.2 renders inside a channel and nowhere else.
nonisolated struct Vitals: Codable, Sendable, Hashable {
    /// Characters-derived, per SERVER-PLAN 9.2. Labelled `ch/s`, never `tok/s`,
    /// and never as a billing figure.
    let tokensPerSec: Double
    let toolsPerMin: Double
    let lastToolAt: Double?
    /// Seconds. `nil` when not blocked.
    let blockedFor: Double?
    /// 0...1 from the statusLine payload's `used_percentage/100`. `nil` means
    /// not yet sampled, which is a different fact from zero.
    let contextUsed: Double?
}

// MARK: - Capability

/// A control the *server* says exists. The app hardcodes only the endpoint and
/// body shape for each `id` it knows how to dispatch; it never hardcodes which
/// capabilities exist, their order, their label, their enabled state or their
/// reason.
nonisolated struct Capability: Codable, Sendable, Hashable, Identifiable {
    let id: String        // "stop" | "kill" | "retask" | "resume" | "new" | "compact"
    let label: String
    let enabled: Bool
    let reason: String?

    /// The ids this build knows how to send. A capability outside this set
    /// renders **disabled with the server's label**, not hidden: hiding it
    /// makes a server that has moved ahead of the app invisible, and needing a
    /// new build is exactly the thing that is expensive to discover any other
    /// way.
    static let dispatchable: Set<String> = ["stop", "kill", "retask", "resume", "new", "compact"]

    var known: Bool { Self.dispatchable.contains(id) }
    var usable: Bool { enabled && known }

    /// What to say when it is tapped and cannot run.
    var refusal: String? {
        if !known { return "this build can't do that yet." }
        if !enabled { return reason ?? "not available right now." }
        return nil
    }
}

// MARK: - Moment

/// One line of an agent's channel, keyed on the store's single global `seq`.
///
/// `id` is that seq rather than a per-conversation index, which is what lets a
/// ring's Q&A, a delegated `say` and hook-reported tool events interleave in
/// one thread and stay ordered.
nonisolated struct Moment: Identifiable, Hashable, Sendable, Codable {
    nonisolated enum Kind: String, Sendable, Hashable, Codable {
        case you        // what he sent
        case claude     // what the agent answered
        case tool       // what it is running
        case summary
        case state
        case error

        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = Kind(rawValue: raw) ?? .summary
        }
    }

    let seq: Int
    let kind: Kind
    let text: String
    let tool: String?
    let at: Date
    let conversation: String?
    /// SERVER-PLAN 2: rows a subagent produced are dimmed and indented.
    let viaSubagent: Bool
    let phase: String?
    /// How long the tool call took. APP-PLAN 11's third ask; the store keeps it
    /// as a REAL and omits the key entirely when it has nothing to say. **A
    /// tool row without it renders with no bar, never a guessed one.**
    let durationMs: Double?
    /// APP-PLAN 11's fourth ask, echoed on the event a write produced. When it
    /// is here, reconciliation is exact; when it is absent, `Channel` falls
    /// back to FIFO, which is sound because this phone is the only writer.
    let clientToken: String?

    var id: Int { seq }
    var isFromHim: Bool { kind == .you }

    /// Seconds, and only when the server measured them.
    var duration: TimeInterval? { durationMs.map { $0 / 1000 } }

    private enum CodingKeys: String, CodingKey {
        case seq, kind, text, tool, at, conversation, viaSubagent, phase
        case durationMs = "duration_ms"
        case clientToken = "client_token"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        kind = try c.decode(Kind.self, forKey: .kind)
        text = try c.decode(String.self, forKey: .text)
        tool = try c.decodeIfPresent(String.self, forKey: .tool)
        at = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .at))
        conversation = try c.decodeIfPresent(String.self, forKey: .conversation)
        viaSubagent = try c.decodeIfPresent(Bool.self, forKey: .viaSubagent) ?? false
        phase = try c.decodeIfPresent(String.self, forKey: .phase)
        durationMs = try c.decodeIfPresent(Double.self, forKey: .durationMs)
        clientToken = try c.decodeIfPresent(String.self, forKey: .clientToken)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(kind, forKey: .kind)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(tool, forKey: .tool)
        try c.encode(at.timeIntervalSince1970, forKey: .at)
        try c.encodeIfPresent(conversation, forKey: .conversation)
        if viaSubagent { try c.encode(true, forKey: .viaSubagent) }
        try c.encodeIfPresent(phase, forKey: .phase)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encodeIfPresent(clientToken, forKey: .clientToken)
    }

    init(seq: Int, kind: Kind, text: String, tool: String? = nil, at: Date,
         conversation: String? = nil, viaSubagent: Bool = false, phase: String? = nil,
         durationMs: Double? = nil, clientToken: String? = nil) {
        self.seq = seq
        self.kind = kind
        self.text = text
        self.tool = tool
        self.at = at
        self.conversation = conversation
        self.viaSubagent = viaSubagent
        self.phase = phase
        self.durationMs = durationMs
        self.clientToken = clientToken
    }
}

// MARK: - Phase

/// One leg of the route, from `/agents/history`'s phase records. The map (step
/// 8) renders these; the type lives here because it is wire data.
nonisolated struct Phase: Codable, Sendable, Hashable, Identifiable {
    let id: String
    let title: String
    let outcome: String?
    let startedAt: Double
    let endedAt: Double?

    private enum CodingKeys: String, CodingKey {
        case id, title, outcome
        case startedAt = "started_at"
        case endedAt = "ended_at"
    }
}

// MARK: - Pages

nonisolated struct AgentsPage: Codable, Sendable {
    let agents: [Agent]
}

nonisolated struct FeedPage: Codable, Sendable {
    let agent: AgentID
    let events: [Moment]
    let cursor: Int
    let closed: Bool
    let historyGeneration: Int?
}

nonisolated struct HistoryPage: Codable, Sendable {
    let agent: AgentID
    let events: [Moment]
    let oldestSeq: Int?
    let newestSeq: Int?
    let hasMore: Bool
    let historyGeneration: Int?
    let phases: [Phase]?

    private enum CodingKeys: String, CodingKey {
        case agent, events, phases, historyGeneration
        case oldestSeq = "oldest_seq"
        case newestSeq = "newest_seq"
        case hasMore = "has_more"
    }
}

/// An open conversation, from `/api/v1/conversations`.
///
/// The app needs this for one reason: **a ring opens a conversation on the
/// server**, so the phone was never told its id, and `/api/v1/reply` targets one
/// specific conversation. Without it the question is sitting there and the
/// composer has no way to answer it.
nonisolated struct Waiting: Codable, Sendable, Hashable, Identifiable {
    let conversation: String
    let opened: Double?
    let asked: String?
    let answered: Bool?
    let closed: Bool?
    let waiting: Bool?
    /// Additive: which channel this belongs to, so the app can group by agent
    /// without a second round trip. Absent on a daemon that predates it.
    let agent: AgentID?

    var id: String { conversation }
    var isOpen: Bool { waiting ?? (!(answered ?? false) && !(closed ?? false)) }
}

nonisolated struct ConversationsPage: Codable, Sendable {
    let conversations: [Waiting]
}

/// One roster invalidation. It is a tick, not a fact: it says a cached row is
/// stale and nothing more, which is why a duplicate costs one refetch and is
/// not worth machinery to prevent.
nonisolated struct RosterEvent: Codable, Sendable, Hashable {
    let seq: Int
    let agent: AgentID?
    let text: String?
    let at: Double?
}

nonisolated struct RosterTick: Codable, Sendable {
    let events: [RosterEvent]
    let cursor: Int
}

/// `/health`. Every field is optional because this endpoint has grown twice
/// already and will again.
nonisolated struct Health: Codable, Sendable {
    let ok: Bool?
    let fake: Bool?
    let ringReady: Bool?
    let uptimeSeconds: Double?
    let transport: String?
    let dbOk: Bool?
    let dbBytes: Int?
    let diskFree: Int?
    let degradations: [String]?
    /// `new`, for pull-up-past-the-bottom. Absent until server step 8.
    let globalControls: [Capability]?

    private enum CodingKeys: String, CodingKey {
        case ok, fake, transport, degradations, globalControls
        case ringReady = "ring_ready"
        case uptimeSeconds = "uptime_seconds"
        case dbOk = "db_ok"
        case dbBytes = "db_bytes"
        case diskFree = "disk_free"
    }
}

// MARK: - Control results

nonisolated struct PurgeCounts: Codable, Sendable {
    let agent: AgentID
    let conversations: Int
    let events: Int
    let phases: Int
    let oldestAt: Double?
    let dryRun: Bool?

    private enum CodingKeys: String, CodingKey {
        case agent, conversations, events, phases
        case oldestAt = "oldest_at"
        case dryRun = "dry_run"
    }
}

nonisolated struct RetireResult: Codable, Sendable {
    let agent: AgentID
    let retired: Bool
}

nonisolated struct StopResult: Codable, Sendable {
    let agent: AgentID
    let interrupted: Bool
}

nonisolated struct KillResult: Codable, Sendable {
    let agent: AgentID
    let outcome: String
}

nonisolated struct RetaskResult: Codable, Sendable {
    let agent: AgentID
    /// `queued` and `delivered` are different outcomes and read differently:
    /// "queued -- it will start after the current turn" is not "started".
    let delivered: Bool
    let queued: Bool
    /// Echoed back, so the `you` event this produced can be recognised.
    let clientToken: String?
}

nonisolated struct ResumeResult: Codable, Sendable {
    let agent: AgentID
    let session: String?
    let fromHandoff: Bool?

    private enum CodingKeys: String, CodingKey {
        case agent, session
        case fromHandoff = "from_handoff"
    }
}

nonisolated struct NewResult: Codable, Sendable {
    let agent: AgentID
    let session: String?
}

nonisolated struct SayResult: Codable, Sendable {
    let conversation: String
}

/// Real numbers read out of the transcript's `compact_boundary` record --
/// not a timer and not an estimate. `resumed: false` is a valid, honest
/// outcome and is neither an error nor a success.
nonisolated struct CompactResult: Codable, Sendable {
    let agent: AgentID?
    let interrupted: Bool
    let compacted: Bool
    let resumed: Bool
    let preTokens: Int?
    let postTokens: Int?
    let durationMs: Int?
    let detail: String?
}
