import Foundation
import OSLog

/// The connection to `hotline-iosd` on archserver, over Tailscale.
///
/// Two jobs, deliberately separate:
///
///   * **the event feed** -- long-poll with a cursor, which is what the server
///     offers. Not a WebSocket, and that is not an accident: this phone moves
///     between wifi and cellular, every long-lived connection dies at the
///     handover, and a cursor makes the reconnect one request that loses
///     nothing. See `events.py` on the server for the same reasoning.
///   * **placing and controlling calls** -- ordinary requests.
///
/// `nonisolated` on the whole type: none of this touches UI, and a library-ish
/// component should let the caller decide where it runs rather than dragging
/// the main actor into a socket read.
nonisolated final class Link: Sendable {
    private let base: URL
    private let session: URLSession
    private let log = Logger(subsystem: "dev.stamenovic.hotlinecall", category: "link")

    init(base: URL) {
        self.base = base
        let config = URLSessionConfiguration.ephemeral
        // Longer than the server's 25 s long-poll ceiling, so a quiet call is
        // not mistaken for a dead one.
        config.timeoutIntervalForRequest = 40
        config.waitsForConnectivity = true
        // The tailnet is not always up the instant we ask -- iOS starts the VPN
        // from an on-demand rule and a Tailscale contributor measured 5-10 s
        // for that. Waiting beats failing and retrying.
        self.session = URLSession(configuration: config)
    }

    enum Failure: Error {
        case http(Int)
        case malformed
    }

    /// Everything after `cursor`. Blocks server-side until something arrives.
    func events(callID: String, after cursor: Int) async throws -> EventPage {
        var request = URLRequest(url: base.appending(path: "api/v1/events"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "call_id": callID, "since": cursor, "wait": 25,
        ])
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        guard http.statusCode == 200 else { throw Failure.http(http.statusCode) }
        return try JSONDecoder().decode(EventPage.self, from: data)
    }

    /// A stream of moments for one call, reconnecting across network changes.
    ///
    /// The cursor lives outside the request, so a wifi-to-cellular handover
    /// costs one retry and drops nothing. `AsyncStream` rather than a delegate
    /// so the view can `for await` it and cancellation is structural.
    func moments(callID: String) -> AsyncStream<Moment> {
        AsyncStream { continuation in
            let task = Task {
                var cursor = 0
                var backoff = Duration.milliseconds(250)
                while !Task.isCancelled {
                    do {
                        let page = try await events(callID: callID, after: cursor)
                        if page.gap {
                            // Say so in the transcript itself. A hole nobody is
                            // told about looks exactly like nothing happening.
                            continuation.yield(Moment(
                                id: cursor, kind: .error,
                                text: "— some of this call was missed —",
                                tool: nil, at: .now))
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

    func hangUp(callID: String) async {
        var request = URLRequest(url: base.appending(path: "api/v1/hangup"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["call_id": callID])
        _ = try? await session.data(for: request)
    }
}
