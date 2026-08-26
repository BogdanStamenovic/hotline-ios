import Foundation

/// The blocked-agent arrival (APP-PLAN 4.6), as the values its six beats drive.
///
/// **This is the app's most important animation because it is the one moment
/// where it is telling him something rather than answering him.** Nobody tapped
/// anything: a roster tick came back with an agent's `blocked` flipped, and the
/// beats stage the news so the order it travels in is legible instead of
/// arriving as one jump.
///
/// The sequencer lives on `Fleet` rather than in a view, for two reasons that
/// are both correctness rather than taste:
///
/// - **it fires whether or not that agent has ever been opened**, and a channel
///   that has never existed cannot own a sequence;
/// - the beats change the *display order*, and the display order is `Fleet`'s.
///   Staging it anywhere else means two writers for `order`.
nonisolated struct ArrivalBeats: Sendable, Equatable {
    /// 140 ms. The subtitle blur-crossfades to the question, the timestamp
    /// becomes "now", the `NEEDS YOU` tag rises.
    var words: Double = 0
    /// 320 ms. The `sig10` wash wipes across left to right and the 2 pt pin bar
    /// reveals. 640 ms on the way in, 300 ms on the way out: entering is
    /// deliberate, leaving is the system responding.
    var wash: Double = 0
    /// 320 ms. The mover is lifted off the plane while it climbs -- a row that
    /// climbs past other rows has to be *above* them, or the pass reads as a
    /// rendering glitch.
    var lift: Double = 0
    /// The z-order and shadow, dropped at +860 ms. Separate from `lift` because
    /// it is a discrete class rather than a curve, and dropping it with the
    /// curve puts the row back under its neighbours while it is still settling.
    var lifted = false

    var isQuiet: Bool { words == 0 && wash == 0 && lift == 0 && !lifted }
}

/// One agent's `blocked` flag changed, and the choreography it owes.
struct Arrival: Identifiable, Equatable, Sendable {
    let id = UUID()
    let agent: AgentID
    /// The same beats run in reverse on the faster curves. Enter is deliberate;
    /// exit is the system responding.
    let unblocking: Bool
    let at: Date
    /// What it is asking, when the daemon holds an open conversation for it.
    var question: String?
}
