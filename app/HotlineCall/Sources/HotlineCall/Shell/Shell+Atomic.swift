import SwiftUI

// The slam card's sequencer, and the three flows that reach it (APP-PLAN 9).
//
// It is an extension rather than a separate type so the three animated tracks
// and the lock stay `@State` on `Shell` -- they are presentation, and `Shell`
// is where APP-PLAN 2.1 says every progress value in this app lives.

extension Shell {

    /// **`PhaseAnimator` is the obvious SwiftUI tool and is the wrong one:** it
    /// does not express a real dwell independent of its transitions, and it
    /// wants one timeline where this needs two. The card is driven by one
    /// main-actor `Task` that awaits `Task.sleep` between beats and drives three
    /// independent values with `withAnimation` -- a 1:1 map onto the beat sheet,
    /// **with the held beat as a literal sleep containing nothing.**
    ///
    /// If a reviewer cannot point at a `Task.sleep(for: .milliseconds(320))`
    /// with nothing scheduled in it, the port is wrong. It is the beat Bogdan
    /// praised: a reading pause rather than an animation, which is why it
    /// survives Reduce Motion at 150 ms instead of being removed.
    func runAtomic(_ run: AtomicRun, preDelay: Double, after: @escaping () -> Void) {
        guard atomic == nil else { return }
        let channel = run.agent.map { fleet.channel(for: $0) }

        atomic = run
        // Two calls, symmetric, impossible to leave half-done. Between them the
        // feed **keeps running** -- the cursor still advances and the cache is
        // still written -- and only the visible array waits, so the self-cut
        // re-staggers the final state exactly once instead of a thread that
        // changed twice behind the card.
        channel?.beginAtomicPresentation()
        fleet.holdChoreography()
        Haptics.shared.play(run.flow.pattern)

        Task {
            defer {
                channel?.endAtomicPresentation()
                fleet.releaseChoreography()
                atomic = nil
                committing = false
                // The self-cut: the destination replays its own arrival, even
                // when the destination is the screen he is already looking at.
                sceneEpoch &+= 1
                after()
            }

            let quiet = reduceMotionValue
            // APP-PLAN 9.8's table, in one place. Same sequence, same order,
            // every directional transform stripped (that is `mo`), durations
            // compressed ~2.5-3x, **and all stagger removed** -- so under Reduce
            // Motion the three content tracks start together rather than 90 and
            // 330 ms apart. What does not compress is the held beat.
            let scale = quiet ? 0.36 : 1.0
            let wordDelay = quiet ? 0 : 90
            let subDelay = quiet ? 0 : 240
            let tail = quiet ? 220 : 500

            // t = preDelay. Flow A fires 60 ms before the option's zoom
            // finishes, so the rising wipe overtakes and buries its tail.
            try? await Task.sleep(for: .milliseconds(Int(preDelay * scale)))
            reveal = 0
            exitInset = 0
            wordIn = 0
            subIn = 0
            withAnimation(quiet ? .easeOut(duration: 0.22)
                                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.46)) {
                reveal = 1
            }

            // +90 ms. The word runs to 330 ms *past* the wipe's own completion,
            // so it keeps settling while the card is already static.
            try? await Task.sleep(for: .milliseconds(wordDelay))
            withAnimation(quiet ? .easeOut(duration: 0.22)
                                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.70)) {
                wordIn = 1
            }

            // +240 ms. The headline commits; the receipt confirms after.
            try? await Task.sleep(for: .milliseconds(subDelay))
            withAnimation(quiet ? .easeOut(duration: 0.22)
                                : .timingCurve(0.23, 1, 0.32, 1, duration: 0.50)) {
                subIn = 1
            }

            // Out to the end of the sub-line's own run.
            try? await Task.sleep(for: .milliseconds(tail))

            // ---- THE HELD BEAT. Nothing moves. No animation is scheduled
            // inside this sleep, and nothing may ever be put in it.
            try? await Task.sleep(for: .milliseconds(quiet ? 150 : 320))

            // The exit. Both boundaries travel upward: this is the band's
            // *bottom* edge rising, not the wipe reversing.
            withAnimation(quiet ? .easeOut(duration: 0.18)
                                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.40)) {
                exitInset = 1
            }
            try? await Task.sleep(for: .milliseconds(quiet ? 180 : 400))
        }
    }

    // MARK: - Flow A: answering

    /// The commit is the answer card's drag-right release, which is `t = 0`.
    ///
    /// **The card never fabricates the agent's reply to fill the beat.** The
    /// real reply usually arrives during the hold and the exit shows it; when it
    /// has not, the exit shows the question gone and his answer in place, and
    /// the reply lands later with the ordinary fresh-message animation. The
    /// prototype invents canned text at +1700 ms because it had no server.
    func answer(_ agent: Agent, _ channel: Channel, _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, atomic == nil else { return }
        // The optimistic bubble is appended now, invisible behind the card.
        channel.send(trimmed)
        committing = true
        runAtomic(AtomicRun(flow: .answer, word: "SENT",
                            sub: trimmed, kicker: agent.name, agent: agent.name),
                  preDelay: 560) {}
    }

    // MARK: - Flow B: killing

    /// After the 1 500 ms hold completes, `t = 0`.
    ///
    /// **No navigation.** You stay where you are: the channel header's state
    /// line swaps instantly with no animation and the list row behind updates in
    /// place, its dot going to the hollow dead ring and its subtitle
    /// blur-crossfading to the `deadReason`.
    ///
    /// The source's per-character status roll is dropped -- it is a component of
    /// Editorial's UI rather than its motion, and importing it would import
    /// Editorial's typography through the back door, which is the one thing this
    /// port is not allowed to do.
    func killWithCard(_ agent: Agent) {
        guard atomic == nil, busyControl == nil else { return }
        busyControl = "kill"
        dismissSheet()
        runAtomic(AtomicRun(flow: .kill, word: "KILLED",
                            sub: "The session is gone. It only comes back through Resume.",
                            kicker: agent.name, agent: agent.name),
                  preDelay: 260) {}
        Task {
            defer { busyControl = nil }
            switch await fleet.kill(agent.name) {
            case .ok(let result):
                commit &+= 1
                if result.outcome != "killed" {
                    toast = Toast(text: "Killed — \(result.outcome)")
                }
            case .failed(let why):
                // The card said it happened and it did not. Say so plainly
                // rather than leaving the optimistic state standing.
                toast = Toast(text: why)
            }
        }
    }

    // MARK: - Flow C: purging

    /// Flow B exactly: same hold-to-fill, same haptic pattern, word `DELETED`,
    /// **sub-line = the dry-run counts**. The counts are the consent, so they
    /// are also the receipt.
    func purge(_ agent: Agent, scope: String, beforeSeq: Int?, counts: PurgeCounts) {
        guard atomic == nil, busyControl == nil else { return }
        busyControl = "purge"
        dismissSheet()
        runAtomic(AtomicRun(flow: .purge, word: "DELETED",
                            sub: purgeSentence(counts), kicker: agent.name,
                            agent: agent.name),
                  preDelay: 260) {}
        Task {
            defer { busyControl = nil }
            switch await fleet.purge(agent.name, scope: scope, beforeSeq: beforeSeq) {
            case .ok:
                commit &+= 1
                // Only when the agent record itself went: the local copy
                // disappears as a side effect of the real deletion succeeding.
                if scope == "everything", open == agent.name { leave() }
            case .failed(let why):
                toast = Toast(text: why)
            }
        }
    }
}
