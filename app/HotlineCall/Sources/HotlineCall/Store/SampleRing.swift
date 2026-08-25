import Foundation

/// One reading of an agent's throughput, at a real instant.
///
/// A value type, and that is load-bearing rather than stylistic: `Shape.path(in:)`
/// runs off the main actor, so **a mark can never be handed a `Channel`.** The
/// view decimates on the main actor and passes values.
nonisolated struct Sample: Sendable, Hashable {
    let at: Date
    /// Characters per second, per SERVER-PLAN 9.2. Never a token count and
    /// never a billing figure.
    let charsPerSec: Double
    let toolsPerMin: Double
    let blockedFor: TimeInterval?
}

/// The channel's own rolling window of samples.
///
/// **It belongs to the `Channel` and is discarded with it.** There is no
/// fleet-wide sample store, because there is no fleet-wide readout
/// (APP-PLAN 5.0).
nonisolated struct SampleRing: Sendable, Hashable {
    /// 360 samples is about 30 minutes at the 5 s roster cadence a channel
    /// holds open -- which is exactly the widest window the scrub offers.
    static let capacity = 360

    private(set) var samples: [Sample] = []

    var isEmpty: Bool { samples.isEmpty }
    var newest: Sample? { samples.last }
    var oldest: Sample? { samples.first }

    /// Trimmed with a **single** `removeFirst(k)`. `removeFirst()` in a loop
    /// makes appending O(n^2), which is the kind of clean-looking regression
    /// that only shows up after half an hour of watching one agent.
    mutating func append(_ sample: Sample) {
        // Out-of-order or duplicate wakes would put a kink in a mark plotted
        // against real time. The roster can deliver the same tick twice.
        if let last = samples.last, sample.at <= last.at { return }
        samples.append(sample)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// Seed the window with readings derived from the transcript itself, for
    /// the stretch before this app was sampling.
    ///
    /// It is the same measurement at a coarser resolution -- characters of
    /// assistant text over the wall time between them -- not a second metric
    /// dressed as the first, which is why merging them into one curve is
    /// honest. Only fills below the oldest live sample, so a real reading is
    /// never overwritten by a reconstruction.
    mutating func seed(_ earlier: [Sample]) {
        guard !earlier.isEmpty else { return }
        let floorDate = samples.first?.at ?? .distantFuture
        let kept = earlier.filter { $0.at < floorDate }.sorted { $0.at < $1.at }
        guard !kept.isEmpty else { return }
        samples = kept + samples
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }

    /// The samples inside a span, ending now.
    func window(_ span: TimeInterval, now: Date = .now) -> [Sample] {
        let floorDate = now.addingTimeInterval(-span)
        return samples.filter { $0.at >= floorDate }
    }
}

/// Rebuild a throughput series out of the events the channel already holds.
///
/// Characters of assistant text between consecutive assistant events, divided
/// by the wall time between their timestamps. Real, and coarse, and it **stops
/// where the fetched history stops** -- nothing is synthesised to fill the gap,
/// which is why the mark simply has no points there rather than a line back to
/// zero.
nonisolated func rebuiltSamples(from moments: [Moment]) -> [Sample] {
    var out: [Sample] = []
    var previous: Moment?
    var toolTimes: [Date] = []

    for moment in moments {
        if moment.kind == .tool { toolTimes.append(moment.at) }
        guard moment.kind == .claude else { continue }
        defer { previous = moment }
        guard let last = previous else { continue }
        let elapsed = moment.at.timeIntervalSince(last.at)
        // Two events in the same instant carry no rate. Dividing by ~0 would
        // put a spike in the mark that means nothing happened fast.
        guard elapsed >= 0.5 else { continue }
        let minute = moment.at.addingTimeInterval(-60)
        out.append(Sample(
            at: moment.at,
            charsPerSec: Double(moment.text.count) / elapsed,
            toolsPerMin: Double(toolTimes.filter { $0 >= minute && $0 <= moment.at }.count),
            blockedFor: nil))
    }
    return out
}
