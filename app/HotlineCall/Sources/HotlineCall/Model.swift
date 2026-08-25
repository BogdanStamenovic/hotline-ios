import Foundation

/// One line of what happened on a call.
///
/// A value type with no reference storage, so it is `Sendable` for free and can
/// cross from the socket task to the main actor without ceremony.
struct Moment: Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case heard      // what he said, as transcribed
        case said       // what Claude answered
        case tool       // what Claude is running right now
        case summary
        case state
        case error
    }

    let id: Int
    let kind: Kind
    let text: String
    let tool: String?
    let at: Date

    var isFromHim: Bool { kind == .heard }
}

/// The whole of a call, as one value.
///
/// Modelled as an enum rather than a bag of optionals so that "ringing but also
/// has a transcript" cannot be spelled, and so a state change is one assignment
/// instead of a sequence of property writes that can be left half-finished.
enum CallPhase: Equatable, Sendable {
    case idle
    case ringing(from: String, reason: String)
    case connected(since: Date)
    case ended(reason: String)

    var isLive: Bool {
        if case .connected = self { return true }
        return false
    }
}

/// What the server sends down the event feed.
struct ServerEvent: Codable, Sendable {
    let seq: Int
    let kind: String
    let text: String
    let tool: String?
    let at: Double
}

struct EventPage: Codable, Sendable {
    let call_id: String
    let events: [ServerEvent]
    let cursor: Int
    let closed: Bool
    /// True when our cursor is older than anything the server still holds, so
    /// we have provably missed events. Surfaced rather than hidden: a
    /// transcript with a silent hole in it is worse than one that says so.
    let gap: Bool
}
