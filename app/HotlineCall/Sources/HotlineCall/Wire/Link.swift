import Foundation
import OSLog

/// The connection to `hotline-iosd` on archserver, over Tailscale.
///
/// Everything here is direct to his own machine. Telegram rings the phone; from
/// the moment he opens the app, nothing touches a cloud.
///
/// `nonisolated` on the type: none of this touches UI, and a transport should
/// let the caller decide where it runs rather than dragging the main actor into
/// a network read. There is no mutable state beyond a `URLSession`, so it can
/// be captured by any task without ceremony.
nonisolated final class Link: Sendable {
    private let base: URL
    private let session: URLSession
    private let log = Logger(subsystem: "dev.stamenovic.hotline", category: "link")

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        // Longer than the server's 25 s long-poll ceiling, so a quiet agent is
        // not mistaken for a dead connection.
        config.timeoutIntervalForRequest = 40
        // The tailnet is not always up the instant we ask: iOS starts the VPN
        // from an on-demand rule, and a Tailscale contributor measured 5-10 s
        // for that. Waiting beats failing and making him retry by hand.
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    enum Failure: LocalizedError, Equatable {
        case http(Int, String?)
        case malformed

        var errorDescription: String? {
            switch self {
            // The server's own message when it sent one. A 409 from `/stop`
            // says "already interrupting", and rendering that beats rendering
            // "archserver said 409".
            case .http(let code, let message): message ?? "archserver said \(code)"
            case .malformed: "archserver sent something unreadable"
            }
        }

        /// The endpoint is not on this daemon. Distinct from a real failure,
        /// because the app degrades rather than complains.
        var isMissingEndpoint: Bool {
            if case .http(404, _) = self { return true }
            return false
        }
    }

    // MARK: - Transport

    private func post<T: Decodable>(_ path: String, _ body: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "GET"
        return try await send(request)
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard http.statusCode == 200 else {
            throw Failure.http(http.statusCode, Self.message(in: data))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            log.error("decode \(String(describing: T.self), privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw Failure.malformed
        }
    }

    /// hotline's httpd puts its refusals in `{"error": "..."}`. Best effort --
    /// a body that is not that shape simply yields the status code.
    private static func message(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        for key in ["error", "message", "detail"] {
            if let text = object[key] as? String, !text.isEmpty { return text }
        }
        return nil
    }

    // MARK: - Roster

    func health() async throws -> Health {
        try await get("health")
    }

    func agents(includeDone: Bool = false, includeRetired: Bool = false) async throws -> [Agent] {
        let page: AgentsPage = try await post("api/v1/agents", [
            "include_done": includeDone, "include_retired": includeRetired,
        ])
        return page.agents
    }

    /// The invalidation tick. Long-poll: it returns when the roster stops being
    /// true, or when `wait` seconds are up, whichever comes first.
    func rosterEvents(since cursor: Int, wait: Double) async throws -> RosterTick {
        try await post("api/v1/agents/roster-events", ["since": cursor, "wait": wait])
    }

    // MARK: - Channels

    func feed(agent: AgentID, since cursor: Int, wait: Double) async throws -> FeedPage {
        try await post("api/v1/agents/feed", ["agent": agent, "since": cursor, "wait": wait])
    }

    /// A page of an agent's past, walking backwards. `before` is exclusive and
    /// is the `oldestSeq` of the page you already have, so paging has no
    /// off-by-one at either end and meets the live feed exactly once.
    func history(agent: AgentID, before: Int?, limit: Int = 200) async throws -> HistoryPage {
        var body: [String: Any] = ["agent": agent, "limit": min(limit, 200)]
        if let before { body["before"] = before }
        return try await post("api/v1/agents/history", body)
    }

    // MARK: - Talking

    /// Give an agent something to do. Returns the conversation key.
    func say(_ text: String, to agent: AgentID?) async throws -> String {
        var body: [String: Any] = ["text": text]
        // Omitted rather than sent as null: the server reads a missing agent as
        // "the newest session", which is a different instruction from "no
        // agent" and the one he means when he has not picked.
        if let agent { body["agent"] = agent }
        let page: SayResult = try await post("api/v1/say", body)
        return page.conversation
    }

    /// Every conversation the daemon still holds open, newest first.
    ///
    /// A ring opens a conversation server-side, so this is the only way the
    /// phone can learn the id it has to answer. Older daemons carry no `agent`
    /// field, which is why `Waiting.agent` is optional rather than assumed.
    func conversations() async throws -> [Waiting] {
        let page: ConversationsPage = try await post("api/v1/conversations")
        return page.conversations
    }

    private struct Delivered: Decodable { let delivered: Bool }

    /// Answer a question a ring opened. Distinct from `say`, which starts a new
    /// conversation -- this one unblocks an agent already waiting on it.
    func reply(_ text: String, to conversation: String) async throws {
        let _: Delivered = try await post("api/v1/reply", [
            "conversation": conversation, "text": text,
        ])
    }

    // MARK: - Control
    //
    // The app hardcodes the endpoint and body shape for each id -- that is an
    // ordinary client/server contract. It hardcodes nothing about whether a
    // control exists, what it is called, or whether it is enabled.

    func stop(agent: AgentID) async throws -> StopResult {
        try await post("api/v1/agents/stop", ["agent": agent])
    }

    func kill(agent: AgentID) async throws -> KillResult {
        try await post("api/v1/agents/kill", ["agent": agent])
    }

    /// One request, composed server-side: two calls from a phone means a
    /// dropped network can leave an agent cancelled with nothing queued.
    ///
    /// `clientToken` is what makes the resulting `you` event identifiable as
    /// *this* write. Sent only where the server reads it: `/say` and `/reply`
    /// ignore the field, so passing it there would be a promise the wire does
    /// not keep.
    func retask(agent: AgentID, text: String, stopFirst: Bool,
                clientToken: String? = nil) async throws -> RetaskResult {
        var body: [String: Any] = ["agent": agent, "text": text, "stop_first": stopFirst]
        if let clientToken { body["client_token"] = clientToken }
        return try await post("api/v1/agents/retask", body)
    }

    func resume(agent: AgentID, cwd: String? = nil) async throws -> ResumeResult {
        var body: [String: Any] = ["agent": agent]
        if let cwd { body["cwd"] = cwd }
        return try await post("api/v1/agents/resume", body)
    }

    func new(task: String, cwd: String? = nil, name: String? = nil) async throws -> NewResult {
        var body: [String: Any] = ["task": task]
        if let cwd { body["cwd"] = cwd }
        if let name { body["name"] = name }
        return try await post("api/v1/agents/new", body)
    }

    func compact(agent: AgentID, then: String? = nil) async throws -> CompactResult {
        var body: [String: Any] = ["agent": agent]
        if let then { body["then"] = then }
        return try await post("api/v1/agents/compact", body)
    }

    // MARK: - Retention

    func retire(agent: AgentID, retired: Bool) async throws -> RetireResult {
        try await post("api/v1/agents/retire", ["agent": agent, "retired": retired])
    }

    /// `dryRun: true` returns the real counts without deleting. The number is
    /// the consent, so the sheet is built from this and never from a generic
    /// warning.
    func purge(agent: AgentID, scope: String, conversation: String? = nil,
               beforeSeq: Int? = nil, dryRun: Bool) async throws -> PurgeCounts {
        var body: [String: Any] = ["agent": agent, "scope": scope, "dry_run": dryRun]
        if let conversation { body["conversation_id"] = conversation }
        if let beforeSeq { body["before_seq"] = beforeSeq }
        return try await post("api/v1/agents/purge", body)
    }
}
