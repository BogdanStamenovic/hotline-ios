import Foundation
import OSLog

/// One agent's transcript, its feed, and the optimistic echoes of what he sent.
///
/// **This type is where two of the three bugs are structurally impossible.**
///
/// *Bug 2 -- a channel showing the previous agent's messages.* There is one
/// `Channel` per agent, created and kept by `Fleet`, and `moments` lives on it.
/// There is no shared array left to leak into. `apply(_:)` additionally traps if
/// a page arrives addressed to somebody else, so cross-talk is a loud
/// precondition failure rather than a silent wrong render.
///
/// *Bug 3 -- the dedup eating repeated messages.* The optimistic bubble is
/// **never put in `moments`**, and no code path in this file compares message
/// text. A send appends to `pending`; the feed's `you` event pops one pending
/// entry positionally. Send "yes" twice and there are two pending entries, two
/// feed events, and both survive.
///
/// *Bug 1 -- the feed that never starts* is fixed one level up: `run()` is
/// driven by `ChannelLayer`'s `.task(id:)`, so the feed is owned by layer
/// lifetime. Nothing in the send path can start or forget to start it, because
/// no code path from `send` to `run` exists.
@Observable
final class Channel {
    let name: AgentID

    /// Server truth, keyed by the store's single global `seq`.
    private(set) var moments: [Moment] = []
    /// Optimistic echoes. **Never in `moments`.** Main-actor view state, not
    /// wire data.
    private(set) var pending: [Pending] = []
    /// What this phone did, recorded where he will look for it. A compact
    /// result is a fact about the session and belongs in the thread rather than
    /// in a toast; it is not written to the cache, because archserver has no
    /// row for it and pretending otherwise would make the local copy diverge.
    private(set) var notes: [Moment] = []

    private(set) var cursor = 0
    private(set) var oldest: Int?
    private(set) var generation = 0
    private(set) var phases: [Phase] = []
    private(set) var samples = SampleRing()
    private(set) var loading: Loading = .cold
    private(set) var hasOlder = false
    private(set) var pagingOlder = false
    /// Bumped once per real `tool` event **on the feed**. The feed carries
    /// every tool call, so the mark it drives is exact -- this is the readout
    /// that could not be honest on a list row and is honest here.
    private(set) var toolFlash = 0
    /// The open, unanswered conversation this agent is blocked on, if the
    /// daemon told us about one. `nil` means the composer starts a new
    /// conversation instead of answering an existing one.
    private(set) var answering: String?

    enum Loading: Equatable, Sendable {
        case cold, refreshing, streaming
        case failed(String)
    }

    /// An optimistic bubble.
    ///
    /// `sinceSeq` is what makes the reconciliation positional without being
    /// naive: it is the highest seq applied when he pressed send, so a `you`
    /// event from *before* that instant can never be mistaken for this one.
    /// That is what lets a history replace and a live feed page run through the
    /// same code path safely.
    struct Pending: Identifiable, Sendable, Equatable {
        enum Delivery: Equatable, Sendable {
            case inFlight
            case failed(String)
        }

        let id = UUID()
        let text: String
        let at: Date
        let sinceSeq: Int
        var token: String?
        var delivery: Delivery = .inFlight

        var isFailed: Bool { if case .failed = delivery { return true }; return false }
    }

    private let link: Link
    private let cache: Cache
    private let log = Logger(subsystem: "dev.stamenovic.hotline", category: "channel")
    /// `.task(id:)` owns the feed's lifetime, and SwiftUI cancels the old task
    /// before starting the new one -- but it does not *await* the old one, so
    /// for a moment two runs overlap. A bool guard would have let the second one
    /// return immediately and leave the channel with no feed at all, which is
    /// bug 1 wearing a different hat. An epoch supersedes instead of blocking:
    /// the newest run always wins and the older loop falls out on its next pass.
    private var epoch = 0
    /// Probed once. The deployed daemon predates `/agents/feed` entirely, and
    /// retrying a 404 every five seconds forever is not degradation, it is a
    /// busy loop with a banner.
    private var channelsMissing = false
    /// Parked while an atomic presentation holds the screen (APP-PLAN 9.2).
    /// The cursor still advances and the cache is still written; only the
    /// visible array waits.
    private var holdback: [Moment] = []
    private var suspended = false
    private var noteSeq = -1
    private var conversationsMissing = false
    private var primed = false

    init(name: AgentID, link: Link, cache: Cache) {
        self.name = name
        self.link = link
        self.cache = cache
    }

    /// Everything the thread draws, in order: server truth, then this phone's
    /// own notes, then what it is still waiting to hear back about.
    var isEmpty: Bool { moments.isEmpty && notes.isEmpty && pending.isEmpty }

    // MARK: - The seam
    //
    // Paint from cache, drop it if the server's generation moved, replace the
    // visible window from an authoritative history page, then stream. One task,
    // because the steps must happen in order -- that is also the only way to
    // guarantee the seam has no hole and no duplicate. SERVER-PLAN 8 asserts the
    // server-side property this rests on: `history(before: nil, limit: k)` and
    // `since(cursor: newestSeq)` return disjoint sets whose union is everything.

    /// Called from `ChannelLayer`'s `.task(id: agentID)` and from nowhere else.
    func run(rosterGeneration: Int) async {
        epoch &+= 1
        let mine = epoch
        await prime(rosterGeneration: rosterGeneration)
        guard !Task.isCancelled, epoch == mine else { return }
        await refresh()
        guard !Task.isCancelled, epoch == mine else { return }
        await stream(mine)
    }

    /// Step 0: paint from the cache.
    ///
    /// APP-PLAN 2.4 asks for this to be synchronous, before any network call
    /// returns. Across an actor boundary literally synchronous is not
    /// reachable, so what it is instead: `Fleet.channel(for:)` starts this at
    /// the instant the row is tapped, which is ~600 ms of scene change before
    /// the thread is legible, and the `Channel` is kept afterwards, so every
    /// re-open in the same session is a plain array read with no hop at all.
    func prime(rosterGeneration: Int) async {
        guard !primed else { return }
        primed = true
        let snapshot = await cache.load(name)
        guard !Task.isCancelled else { return }
        // The generation check comes first, before anything paints. A purge
        // from anywhere -- another client, the CLI, a script -- reaches the
        // phone as a number that does not match.
        if snapshot.found, snapshot.generation != rosterGeneration {
            await cache.drop(name)
            generation = rosterGeneration
            return
        }
        guard moments.isEmpty, !snapshot.moments.isEmpty else { return }
        moments = snapshot.moments
        generation = snapshot.generation
        cursor = snapshot.moments.last?.seq ?? 0
        oldest = snapshot.moments.first?.seq
        samples.seed(rebuiltSamples(from: snapshot.moments))
    }

    /// Step 2: the authoritative window. **Replaces rather than merges**, so a
    /// purge on the server cannot leave stale rows on the phone.
    func refresh() async {
        guard !channelsMissing else { return }
        loading = moments.isEmpty ? .refreshing : .streaming
        do {
            let page = try await link.history(agent: name, before: nil, limit: 200)
            guard !Task.isCancelled else { return }
            precondition(page.agent == name,
                         "history for \(page.agent) arrived on \(name)'s channel")
            apply(history: page)
            loading = .streaming
        } catch is CancellationError {
            return
        } catch let failure as Link.Failure where failure.isMissingEndpoint {
            retire()
            return
        } catch {
            // The cached window is still on screen and is still the truest
            // thing we have. Say what went wrong; do not blank it.
            loading = .failed(describe(error))
            log.error("history \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        await resolveAnswering()
    }

    private func apply(history page: HistoryPage) {
        let events = page.events.sorted { $0.seq < $1.seq }
        moments = events
        cursor = page.newestSeq ?? events.last?.seq ?? cursor
        oldest = page.oldestSeq ?? events.first?.seq
        hasOlder = page.hasMore
        generation = page.historyGeneration ?? generation
        if let list = page.phases { phases = list }
        samples.seed(rebuiltSamples(from: events))
        reconcile(events)
        Task { [cache, name, moments, generation] in
            await cache.replace(name, with: moments, generation: generation)
        }
    }

    /// Step 3: stream. Cancellation is cooperative -- the loop checks, and the
    /// long poll's suspension is cancelled by `URLSession`'s own task
    /// cancellation through the async `data(for:)` bridge.
    private func stream(_ mine: Int) async {
        guard !channelsMissing else { return }
        var backoff = Duration.milliseconds(250)
        while !Task.isCancelled, epoch == mine {
            do {
                let page = try await link.feed(agent: name, since: cursor, wait: 25)
                if Task.isCancelled { return }
                precondition(page.agent == name,
                             "feed for \(page.agent) arrived on \(name)'s channel")
                apply(feed: page)
                loading = .streaming
                backoff = .milliseconds(250)
            } catch is CancellationError {
                return
            } catch let failure as Link.Failure where failure.isMissingEndpoint {
                retire()
                return
            } catch {
                if Task.isCancelled { return }
                loading = .failed(describe(error))
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(5))
            }
        }
    }

    private func apply(feed page: FeedPage) {
        let arrivals = page.events.sorted { $0.seq < $1.seq }
        cursor = max(cursor, page.cursor)
        generation = page.historyGeneration ?? generation
        guard !arrivals.isEmpty else { return }

        // The cache is written whether or not the thread is allowed to move.
        // Nothing is lost while an atomic presentation holds the screen.
        Task { [cache, name, generation] in
            await cache.append(name, arrivals, generation: generation)
        }

        for moment in arrivals where moment.kind == .tool { toolFlash += 1 }
        reconcile(arrivals)

        if suspended {
            holdback += arrivals
        } else {
            moments += arrivals
        }
        if oldest == nil { oldest = arrivals.first?.seq }
    }

    // MARK: - Older history

    /// Pull down past the top of the thread. 200 at a time, walking backwards.
    func older() async {
        guard !pagingOlder, hasOlder, let before = oldest else { return }
        pagingOlder = true
        defer { pagingOlder = false }
        do {
            let page = try await link.history(agent: name, before: before, limit: 200)
            precondition(page.agent == name,
                         "history for \(page.agent) arrived on \(name)'s channel")
            let events = page.events.sorted { $0.seq < $1.seq }
            guard !events.isEmpty else { hasOlder = false; return }
            moments = events + moments
            oldest = page.oldestSeq ?? events.first?.seq
            hasOlder = page.hasMore
            samples.seed(rebuiltSamples(from: events))
        } catch {
            log.error("older \(self.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sending

    /// The optimistic bubble never enters `moments`.
    ///
    /// It goes here, with the cursor it was born at, and the feed's own `you`
    /// event is what removes it. **Nothing compares text.**
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = Pending(text: trimmed, at: .now, sinceSeq: max(cursor, moments.last?.seq ?? 0))
        pending.append(entry)
        Task { await deliver(entry.id) }
    }

    /// A failed send flips its bubble to `.failed` with a retry affordance
    /// instead of vanishing. That is the other half of bug 3: today a send that
    /// throws leaves a bubble on screen that was never delivered.
    func retry(_ id: Pending.ID) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending[index].delivery = .inFlight
        Task { await deliver(id) }
    }

    func discard(_ id: Pending.ID) {
        pending.removeAll { $0.id == id }
    }

    private func deliver(_ id: Pending.ID) async {
        guard let entry = pending.first(where: { $0.id == id }) else { return }
        do {
            if let conversation = answering {
                try await link.reply(entry.text, to: conversation)
                // He answered, so nothing here is blocked on him any more.
                answering = nil
            } else {
                _ = try await link.say(entry.text, to: name)
            }
        } catch {
            guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
            pending[index].delivery = .failed(describe(error))
        }
    }

    /// One `you` event reconciles at most one pending entry.
    ///
    /// **The rule itself is `reconciled(_:in:)` in `Wire/Rules.swift`**, which
    /// is a pure function over values and is therefore the one part of bug 3's
    /// fix that can actually be executed on the machine this is built on.
    private func reconcile(_ arrivals: [Moment]) {
        guard !pending.isEmpty else { return }
        for moment in arrivals where moment.kind == .you {
            let slots = pending.map {
                PendingSlot(token: $0.token, sinceSeq: $0.sinceSeq,
                            inFlight: $0.delivery == .inFlight)
            }
            guard let index = reconciled(moment, in: slots) else { continue }
            pending.remove(at: index)
        }
    }

    /// Which conversation the composer answers, if any. Degrades to starting a
    /// new one when the daemon has no `/conversations` -- probed once.
    private func resolveAnswering() async {
        guard !conversationsMissing else { return }
        do {
            let open = try await link.conversations()
            answering = open
                .filter { $0.isOpen && ($0.agent == nil || $0.agent == name) }
                .first?.conversation
        } catch let failure as Link.Failure where failure.isMissingEndpoint {
            conversationsMissing = true
        } catch {
            // Not fatal: without it the composer starts a new conversation,
            // which still reaches the agent.
            log.notice("conversations: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Notes this phone made

    /// A compaction that compacted and did not resume. Not an error and not a
    /// success: the server declined to fire a continuation and said so, and the
    /// honest rendering is an offer to do it rather than an apology.
    private(set) var continueOffer = false

    func offerContinue() { continueOffer = true }
    func takeContinueOffer() { continueOffer = false }

    @discardableResult
    func note(_ text: String, kind: Moment.Kind = .state) -> Moment {
        // Negative seqs cannot collide with the store's, which start at 1.
        let moment = Moment(seq: noteSeq, kind: kind, text: text, at: .now)
        noteSeq -= 1
        notes.append(moment)
        return moment
    }

    // MARK: - Telemetry

    /// One reading per roster wake, and only when there is one to take. A
    /// missing `Vitals` appends nothing rather than a zero.
    func sample(_ vitals: Vitals?, at instant: Date = .now) {
        guard let vitals else { return }
        samples.append(Sample(at: instant,
                              charsPerSec: vitals.tokensPerSec,
                              toolsPerMin: vitals.toolsPerMin,
                              blockedFor: vitals.blockedFor))
    }

    // MARK: - The atomic presentation seam (APP-PLAN 9.2)

    /// Two calls, symmetric, impossible to leave half-done: `Shell` takes this
    /// at trigger and releases it in a `defer`.
    func beginAtomicPresentation() {
        suspended = true
    }

    /// `holdback` is flushed in **one** write, so the self-cut re-staggers the
    /// final state exactly once instead of a thread that changed twice.
    func endAtomicPresentation() {
        suspended = false
        guard !holdback.isEmpty else { return }
        moments += holdback
        holdback.removeAll()
    }

    // MARK: - Invalidation

    /// The server's history generation moved: everything here is a lie about a
    /// history that no longer exists.
    func invalidate(generation next: Int) {
        moments.removeAll()
        notes.removeAll()
        holdback.removeAll()
        phases.removeAll()
        samples = SampleRing()
        cursor = 0
        oldest = nil
        hasOlder = false
        generation = next
        primed = true      // there is nothing left on disk worth priming from
        loading = .cold
        Task { [cache, name] in await cache.drop(name) }
    }

    /// This daemon does not have agent channels. Not a failure to retry: a
    /// fact about the server, said once. The roster and the controls still work
    /// -- only the transcript does not exist over this wire.
    private func retire() {
        channelsMissing = true
        loading = .failed("archserver has no agent channels yet — its transcript lives on the daemon.")
        log.notice("\(self.name, privacy: .public): no /agents/feed on this daemon")
    }

    private func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
