import Foundation
import OSLog

/// Everything the UI reads. One place, on the main actor.
///
/// `@Observable` rather than `ObservableObject` + `@Published` on each property:
/// SwiftUI tracks exactly the properties a view actually reads, so the tool
/// line redrawing does not invalidate the transcript.
@Observable
final class Store {
    private(set) var agents: [Agent] = []
    private(set) var moments: [Moment] = []
    private(set) var delivery: Delivery = .idle
    /// What the agent is running right now. hotline already emits these; a
    /// screen can show every one because it has none of speech's constraints.
    private(set) var currentTool: String?
    /// Questions agents have rung him about and are blocked waiting on.
    private(set) var waiting: [Waiting] = []
    /// The question he is currently answering, if any. When this is set, what he
    /// types goes back to the blocked agent rather than starting something new.
    private(set) var answering: Waiting?
    var chosen: String?

    private let link: Link
    private let log = Logger(subsystem: "dev.stamenovic.hotline", category: "store")
    private var feed: Task<Void, Never>?

    init(link: Link) { self.link = link }

    var chosenAgent: Agent? { agents.first { $0.name == chosen } }

    func refresh() async {
        do {
            waiting = try await link.waiting().filter(\.waiting)
            agents = try await link.agents()
            // If the session he was talking to has gone, say so rather than
            // silently retargeting his next message at a different agent.
            if let chosen, !agents.contains(where: { $0.name == chosen }) {
                self.chosen = nil
                moments.append(Moment(id: moments.count + 1_000_000, kind: .error,
                                      text: "\(chosen) is no longer live.",
                                      tool: nil, at: .now))
            }
        } catch {
            log.error("agents: \(error.localizedDescription, privacy: .public)")
            delivery = .failed(error.localizedDescription)
        }
    }

    /// Open a question an agent is blocked on. What he types next goes back to
    /// it rather than starting a new conversation.
    func answer(_ question: Waiting) {
        answering = question
        // Empty, not seeded with the question: the feed replays from cursor 0
        // and the question is already the first event in it. Seeding it here
        // showed it twice.
        moments = []
        follow(question.conversation)
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        moments.append(Moment(id: nextLocalID(), kind: .you, text: trimmed, tool: nil, at: .now))
        delivery = .sending
        do {
            if let answering {
                // An agent is blocked on this exact question. Answering it is
                // not the same as saying something new, and getting that wrong
                // leaves it blocked forever while he thinks he replied.
                try await link.reply(trimmed, to: answering.conversation)
                self.answering = nil
                waiting.removeAll { $0.conversation == answering.conversation }
                delivery = .idle
                return
            }
            let conversation = try await link.send(trimmed, to: chosen)
            delivery = .working(since: .now)
            follow(conversation)
        } catch {
            log.error("send: \(error.localizedDescription, privacy: .public)")
            delivery = .failed(error.localizedDescription)
        }
    }

    private func follow(_ conversation: String) {
        feed?.cancel()
        feed = Task { [link] in
            for await moment in link.moments(conversation: conversation) {
                apply(moment)
            }
            if case .working = delivery { delivery = .idle }
        }
    }

    private func apply(_ moment: Moment) {
        // The optimistic local echo and the server's own record of the same
        // message would otherwise both appear.
        if moment.kind == .you, moments.contains(where: {
            $0.kind == .you && $0.text == moment.text
        }) { return }

        moments.append(moment)
        switch moment.kind {
        case .tool: currentTool = moment.tool ?? moment.text
        case .claude:
            currentTool = nil
            delivery = .idle
        default: break
        }
    }

    /// Local echoes are numbered above anything the server will produce, so an
    /// optimistic message can never collide with a real event's sequence.
    private func nextLocalID() -> Int { 1_000_000 + moments.count }
}
