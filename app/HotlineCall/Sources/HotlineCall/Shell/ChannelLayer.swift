import SwiftUI

/// One agent's screen. Everything about the transition is a pure function of
/// `nav`; everything about the content is a fact on its `Channel`.
///
/// **The feed is owned by this layer's lifetime and by nothing else.** That is
/// bug 1 removed rather than patched: `.task(id:)` starts it when this agent
/// becomes the foreground channel and cancels it when it stops being one, and
/// no code path from the composer to `Channel.run` exists to be forgotten. Open
/// a channel and say nothing and messages still arrive.
///
/// `.task(id: agent.name)` is also guard 1 of three against bug 2: SwiftUI
/// cancels the previous task *before* starting the new one, so the old feed
/// cannot deliver into a live view. Guard 2 is `Channel.apply`'s precondition
/// on the page's agent; guard 3 is `Shell`'s `.id(open)` on this layer, so no
/// view state survives a switch either.
struct ChannelLayer: View {
    let agent: Agent
    let channel: Channel
    let nav: Double
    let mo: Double
    /// Bumped after every atomic run. **The self-cut is a hard cut, not a
    /// no-op** (APP-PLAN 9.7): when the answer came from the in-thread question
    /// the destination is the screen he is already looking at, and it still
    /// replays its own arrival. It reads as "this is now a new scene" even
    /// though nothing navigated -- and that is exactly true: the question is
    /// gone, his answer is in, and the agent has moved.
    let cut: Int
    /// Flow A's pre-roll is running on the answer card.
    let committing: Bool
    let onBack: () -> Void
    let onDrag: (ScrubPhase) -> Void
    let onControls: () -> Void
    let onContinue: () -> Void
    let onMapDrag: (SheetPhase) -> Void
    let onAnswer: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 1 settled. Driven to 0 and back on every `cut`.
    @State private var arrival: Double = 1

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    header(viewport: geo.size.height)
                    ThreadView(channel: channel, nav: nav, mo: mo, cut: arrival,
                               onRetry: { channel.retry($0) },
                               onContinue: onContinue)
                        .frame(maxHeight: .infinity)
                    // While a question is open the composer is replaced by the
                    // surface that answers it: one input, one commit gesture.
                    // The composer stays exactly as dumb as it was.
                    if let question = channel.question, channel.answering != nil {
                        AnswerCard(question: question,
                                   blockedSince: agent.blockedAt ?? channel.askedAt,
                                   committing: committing, onCommit: onAnswer)
                            .padding(.horizontal, Theme.edge)
                            .padding(.bottom, 12)
                            .staged(.composer, nav, mo)
                    } else {
                        Composer(answering: channel.answering != nil) { channel.send($0) }
                            .staged(.composer, nav, mo)
                    }
                }

                // The left 44 pt belongs to the back gesture and nothing else.
                // The chevron sits inside that strip, so this recognizer has to
                // answer for taps on itself -- a chevron that swallows its own
                // tap because an ancestor holds the pointer capture is the
                // classic version of this bug, and the fix is not two
                // recognizers but one that handles both outcomes.
                BackStrip(width: geo.size.width, progress: nav,
                          onBack: onBack, onDrag: onDrag)
                    .staged(.backChevron, nav, mo)
            }
            .staged(.channel, nav, mo)
            // The screen cut. Outgoing 260 ms ease-out, incoming 420 ms
            // ease-cine; every message re-staggers from scratch inside
            // `ThreadView`, 52 ms per index.
            .opacity(arrival)
            .scaleEffect(lerp(0.965, 1, arrival))
            .blur(radius: ((1 - arrival) * 5).rounded())
            .offset(y: (1 - arrival) * 20 * mo)
        }
        .onChange(of: cut) { _, _ in selfCut() }
        // The whole seam: paint from cache, drop it if the generation moved,
        // replace the visible window from history, then stream. One task,
        // because the steps must happen in order.
        .task(id: agent.name) {
            await channel.run(rosterGeneration: agent.generation)
        }
    }

    /// A hard cut, deliberately. `withAnimation` on a value that goes 0 then 1
    /// rather than a transition, because the incoming half has to be able to
    /// stagger the thread against the same number.
    private func selfCut() {
        let quiet = reduceMotion
        withAnimation(.easeOut(duration: quiet ? 0.20 : 0.26)) { arrival = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(quiet ? 200 : 260))
            withAnimation(quiet ? .easeOut(duration: 0.16)
                                : .timingCurve(0.16, 1, 0.3, 1, duration: 0.42)) {
                arrival = 1
            }
        }
    }

    // MARK: - Header

    private func header(viewport: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // The hero's destination. Its opacity is a hard swap at e > 0.88,
            // where the travelling copy hides -- one object arriving, not two
            // labels crossfading.
            Text(agent.name)
                .text(.screenTitle)
                .foregroundStyle(Theme.ink)
                .staged(.headerTitle, nav, mo)
                .frame(height: 34, alignment: .leading)
                .padding(.top, HeroDestination.y)

            Rectangle()
                .fill(Theme.sig)
                .frame(width: 120, height: 2)
                .staged(.accentRule, nav, mo)
                .padding(.top, 10)

            HStack(spacing: 10) {
                // Pull it down to open the map. `p = dy / height * 1.35`,
                // and the reveal starts as soon as it is peeking rather than at
                // the commit, so the panel is never a blank rectangle.
                PhaseChip(count: channel.route.phases.count)
                    .staged(.phaseChip, nav, mo)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                onMapDrag(.move(clamp(value.translation.height
                                                      / max(viewport, 1) * 1.35, 0, 1)))
                            }
                            .onEnded { value in
                                onMapDrag(.release(value.velocity.height
                                                   / max(viewport, 1) * 1.35))
                            }
                    )
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Route. \(channel.route.phases.count) phases.")
                    .accessibilityAction { onMapDrag(.move(1)); onMapDrag(.release(0)) }
                Spacer(minLength: 0)
            }
            .padding(.top, 18)

            // **The state line is the control sheet's affordance: tap it.** It
            // is already the place he looks to find out what the agent is
            // doing, so it is the place the controls belong.
            Button(action: onControls) {
                HStack(spacing: 8) {
                    Text(stateLine(agent))
                        .text(.rowSubtitle)
                        .foregroundStyle(agent.isBlocked ? Theme.sigLift : Theme.ink2)
                    ToolDot(flashes: channel.toolFlash)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .staged(.stateLine, nav, mo)
            .padding(.top, 10)
            .accessibilityLabel("\(stateLine(agent)). Controls.")

            InstrumentStrip(agent: agent, channel: channel, nav: nav, mo: mo)
                .padding(.top, 16)

            if case .failed(let why) = channel.loading {
                // The cached window is still on screen and is still the truest
                // thing there is. Say what went wrong; do not blank it.
                Text(why)
                    .text(.label(9.5))
                    .foregroundStyle(Theme.sig)
                    .lineLimit(2)
                    .padding(.top, 10)
            }

            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 18)
        }
        .padding(.leading, HeroDestination.x)
        .padding(.trailing, Theme.edge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The back strip

/// The left 44 pt: one recognizer, two outcomes.
private struct BackStrip: View {
    let width: Double
    let progress: Double
    let onBack: () -> Void
    let onDrag: (ScrubPhase) -> Void

    @State private var startProgress: Double = 1
    @State private var moved = false

    var body: some View {
        HStack {
            Image(systemName: "chevron.left")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.ink2)
                .frame(width: Theme.backStrip, height: 44)
                .padding(.top, 40)
            Spacer()
        }
        .frame(width: Theme.backStrip, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .contentShape(Rectangle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Back to the fleet")
        .accessibilityAction { onBack() }
        // minimumDistance 0 so the same recognizer sees the tap. A separate
        // `Button` here would take the touch before the 6 pt hysteresis could
        // decide whether the finger meant to drag.
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if !moved {
                        // Gated at the *start* only. Re-reading `nav` here
                        // would arm and disarm the recognizer under the finger
                        // as the drag itself pushed it past 0.5, freezing the
                        // gesture halfway.
                        guard progress > 0.5,
                              abs(value.translation.width) >= 6 else { return }
                        moved = true
                        startProgress = progress
                        onDrag(.begin)
                    }
                    onDrag(.move(clamp(startProgress - value.translation.width / width, 0, 1)))
                }
                .onEnded { value in
                    defer { moved = false }
                    if moved {
                        // iOS 17's `velocity`, not a differenced translation:
                        // the difference is a fling that decides at the same
                        // threshold every other fling on the phone does.
                        onDrag(.release(-value.velocity.width / width))
                    } else {
                        onBack()
                    }
                }
        )
    }
}

// MARK: - Header pieces

/// The map's affordance. It says how many phases there are only when the
/// server has sent phase records; an empty route says so rather than showing a
/// count of zero as if that were a measurement.
private struct PhaseChip: View {
    let count: Int

    var body: some View {
        Text(count > 0 ? "ROUTE · \(count)" : "ROUTE")
            .text(.label(9.5))
            .monospacedDigit()
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
    }
}
