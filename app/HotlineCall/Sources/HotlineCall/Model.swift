import Foundation

/// A Claude Code session he can talk to, as hotline's registry knows it.
struct Agent: Identifiable, Hashable, Sendable, Codable {
    let name: String
    let task: String
    let cwd: String
    let live: Bool
    let busy: Bool

    var id: String { name }
}

/// One line of a conversation with an agent.
///
/// A value type with no reference storage, so it is `Sendable` for free and
/// crosses from the network task to the main actor without ceremony.
struct Moment: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case you        // what he sent
        case claude     // what the agent answered
        case tool       // what it is running right now
        case summary
        case state
        case error
    }

    let id: Int
    let kind: Kind
    let text: String
    let tool: String?
    let at: Date

    var isFromHim: Bool { kind == .you }
}

/// What a request to an agent is doing right now.
///
/// An enum rather than a pile of optionals so that "sending and also failed"
/// cannot be spelled, and so a state change is one assignment rather than a
/// sequence of property writes that can be left half-finished.
enum Delivery: Equatable, Sendable {
    case idle
    case sending
    case working(since: Date)
    case failed(String)
}

/// A question an agent rang him about.
///
/// These are opened on the SERVER -- the phone was never involved and has no id
/// for one until it asks. That is why the app lists them rather than only
/// tracking conversations it started itself; without this the question sits
/// there and cannot be found, which is exactly what happened the first time the
/// round trip was run.
struct Waiting: Identifiable, Hashable, Sendable, Codable {
    let conversation: String
    let opened: Double
    let asked: String
    let answered: Bool
    let closed: Bool
    let waiting: Bool

    var id: String { conversation }
    var at: Date { Date(timeIntervalSince1970: opened) }
}

struct ServerEvent: Codable, Sendable {
    let seq: Int
    let kind: String
    let text: String
    let tool: String?
    let at: Double
}

struct EventPage: Codable, Sendable {
    let events: [ServerEvent]
    let cursor: Int
    let closed: Bool
    /// True when our cursor is older than anything the server still holds, so
    /// events have provably been missed. Surfaced rather than hidden: a
    /// transcript with a silent hole in it is worse than one that says so.
    let gap: Bool
}
