import Foundation
import OSLog

/// The connection to `hotline-iosd` on archserver, over Tailscale.
///
/// Everything here is direct to his own machine. Telegram rings the phone; from
/// the moment he opens the app, nothing touches a cloud.
///
/// `nonisolated` on the type: none of this touches UI, and a component like
/// this should let the caller decide where it runs rather than dragging the
/// main actor into a network read.
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

    enum Failure: LocalizedError {
        case http(Int)
        case malformed

        var errorDescription: String? {
            switch self {
            case .http(let code): "archserver said \(code)"
            case .malformed: "archserver sent something unreadable"
            }
        }
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any]) async throws -> T {
        var request = URLRequest(url: base.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct Agents: Decodable { let agents: [Agent] }

    /// Which sessions are live, and what each is working on.
    func agents() async throws -> [Agent] {
        let page: Agents = try await post("api/v1/agents", [:])
        return page.agents
    }

    private struct Sent: Decodable { let conversation: String }

    /// Give an agent something to do. Returns the conversation key to follow.
    func send(_ text: String, to agent: String?) async throws -> String {
        var body: [String: Any] = ["text": text]
        // Omitted rather than sent as null: the server reads a missing agent as
        // "the newest session", which is a different instruction from "no
        // agent" and the one he means when he has not picked.
        if let agent { body["agent"] = agent }
        let page: Sent = try await post("api/v1/say", body)
        return page.conversation
    }

    func events(conversation: String, after cursor: Int) async throws -> EventPage {
        try await post("api/v1/events", [
            "call_id": conversation, "since": cursor, "wait": 25,
        ])
    }

    /// A stream of moments, reconnecting across network changes.
    ///
    /// Long-poll with a cursor rather than a socket, matching the server. This
    /// phone moves between wifi and cellular and every long-lived connection
    /// dies at the handover; the cursor makes a reconnect one request that
    /// loses nothing.
    func moments(conversation: String) -> AsyncStream<Moment> {
        AsyncStream { continuation in
            let task = Task {
                var cursor = 0
                var backoff = Duration.milliseconds(250)
                while !Task.isCancelled {
                    do {
                        let page = try await events(conversation: conversation, after: cursor)
                        if page.gap {
                            // Say so in the transcript itself. A hole nobody is
                            // told about looks exactly like nothing happening.
                            continuation.yield(Moment(
                                id: -cursor - 1, kind: .error,
                                text: "— some of this was missed —", tool: nil, at: .now))
                        }
                        for event in page.events {
                            continuation.yield(Moment(
                                id: event.seq,
                                kind: Moment.Kind(rawValue: event.kind) ?? .summary,
                                text: event.text,
                                tool: event.tool,
                                at: Date(timeIntervalSince1970: event.at)))
                        }
                        cursor = max(cursor, page.cursor)
                        backoff = .milliseconds(250)
                        if page.closed { break }
                    } catch is CancellationError {
                        break
                    } catch {
                        log.error("event feed: \(error.localizedDescription, privacy: .public)")
                        try? await Task.sleep(for: backoff)
                        backoff = min(backoff * 2, .seconds(5))
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
