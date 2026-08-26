import Foundation

// The decisions that have to be right, extracted as pure functions over wire
// values.
//
// This file exists for one practical reason: there is no Mac, no simulator and
// no way to execute SwiftUI on the box this app is built on. `Wire.swift` and
// this file import only Foundation, so they compile and **run** natively on
// Linux with the same toolchain (see `docs/BUILDING.md`), which makes these the
// only rules in the app that can be tested rather than asserted. Everything
// here was moved out of a view or a store deliberately, and the call sites are
// one line each.

// MARK: - Bug 3, as one function

/// One optimistic bubble, reduced to what the reconciliation actually looks at.
///
/// Note what is **not** here: the text. No code path in this app compares
/// message text, which is what makes sending "yes" twice work.
nonisolated struct PendingSlot: Sendable, Equatable {
    /// Present only where the server echoes one -- `/agents/retask` today.
    let token: String?
    /// The highest seq applied when he pressed send.
    let sinceSeq: Int
    let inFlight: Bool
}

/// Which bubble, if any, an arriving `you` event resolves.
///
/// - A **tokened** event resolves the bubble carrying that token, and nothing
///   else. If no bubble matches, it resolves nothing at all -- that is the case
///   a retask produces, and plain FIFO would have let it eat the composer's
///   bubble instead.
/// - An **untokened** event resolves the oldest in-flight bubble that was
///   created *before* it. That is FIFO, and it is sound because this phone is
///   the only writer of `you` events for this agent.
/// - `sinceSeq` is what makes the same rule safe on a history replace: a page
///   of two hundred old `you` events cannot resolve a bubble sent after all of
///   them.
/// - A failed bubble is skipped, so an unrelated echo cannot silently clear a
///   send he still has to retry.
nonisolated func reconciled(_ moment: Moment, in slots: [PendingSlot]) -> Int? {
    guard moment.kind == .you else { return nil }
    if let token = moment.clientToken {
        return slots.firstIndex { $0.token == token }
    }
    return slots.firstIndex { $0.inFlight && $0.sinceSeq < moment.seq }
}

// MARK: - Readouts

/// Tabular, and it does not round up into a lie.
nonisolated func hotlineClock(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return total >= 3600
        ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        : String(format: "%d:%02d", total / 60, total % 60)
}

/// The tool row's duration bar, in points: `clamp(log10(1+s)/log10(61), 0, 1)
/// * 44 + 3`, straight out of APP-PLAN 5.3.
///
/// Log, because a 40 ms `Read` and a 60 s `Bash` share one 44 pt column and a
/// linear scale draws every fast call as the same nothing. **Only ever called
/// with a real `duration_ms`** -- a row without one gets no bar rather than a
/// guessed one.
nonisolated func durationBarWidth(_ seconds: TimeInterval) -> Double {
    let t = log10(1 + max(seconds, 0)) / log10(61)
    return min(max(t, 0), 1) * 44 + 3
}

nonisolated func durationLabel(_ seconds: TimeInterval) -> String {
    if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
    if seconds < 60 { return String(format: "%.1fs", seconds) }
    return "\(Int(seconds / 60))m"
}

/// `Compacted — 48.0k → 4.1k in 71s`.
///
/// Every number in it is one the server read out of the transcript's
/// `compact_boundary` record -- not a timer and not an estimate. A field the
/// server did not send is left out of the sentence entirely rather than
/// defaulted, because "in 0s" would be a measurement nobody took.
///
/// `resumed: false` is a valid, honest outcome: neither an error nor a success.
nonisolated func compactSentence(_ result: CompactResult) -> String {
    guard result.compacted else {
        // Whatever the server said went wrong, verbatim.
        return result.detail ?? "Compaction did not run."
    }
    var out = "Compacted"
    if let before = result.preTokens, let after = result.postTokens {
        out += " — \(tokenCount(before)) → \(tokenCount(after))"
    }
    if let ms = result.durationMs {
        out += " in \(ms / 1000)s"
    }
    if !result.resumed { out += " — not resumed" }
    return out
}

/// One decimal below 10 k, integer above.
nonisolated func tokenCount(_ count: Int) -> String {
    let thousands = Double(count) / 1000
    return thousands < 10 ? String(format: "%.1fk", thousands) : "\(Int(thousands))k"
}
