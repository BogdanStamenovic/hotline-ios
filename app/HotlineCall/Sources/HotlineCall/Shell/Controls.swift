import SwiftUI

/// Every capability the server declared, rendered as the server declared it.
///
/// **The app hardcodes only the endpoint and body shape for each `id` it knows
/// how to dispatch.** It never hardcodes which capabilities exist, their order,
/// their label, their `enabled` or their `reason`. This whole surface is a
/// `ForEach` over `Agent.controls`, and an absent list renders as no controls
/// rather than a guessed one.
///
/// That rule exists because reinstalling costs him a week of provisioning: a
/// build he cannot replace cheaply must be able to be told what it can do.
///
/// Two consequences that are easy to get wrong and are enforced here:
///
/// - A capability whose `id` this build cannot dispatch renders **disabled with
///   the server's label**, never hidden. Hiding it makes a server that has
///   moved ahead of the app invisible; showing it tells him he needs a new
///   build, which is the one thing that is expensive to discover any other way.
/// - `enabled == false` renders visible, dimmed, and **tapping it surfaces the
///   reason**. A disabled control that does nothing when tapped is
///   indistinguishable from a broken one.
struct ControlSheet: View {
    let agent: Agent
    let progress: Double
    let busy: String?
    let onDismiss: () -> Void
    let onDispatch: (Capability) -> Void
    let onRetask: (String, Bool) -> Void
    let onKill: () -> Void
    let onDrag: (SheetPhase) -> Void

    @State private var retasking = false
    @State private var retaskText = ""
    @State private var stopFirst = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(0.55 * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                panel
                    .frame(width: geo.size.width)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                            .fill(Theme.surf)
                            .overlay(
                                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                                    .stroke(Theme.line, lineWidth: 1))
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .offset(y: (1 - progress) * geo.size.height)
                    .gesture(grabber(height: geo.size.height))
            }
        }
        .allowsHitTesting(progress > 0.5)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Capsule()
                .fill(Theme.line2)
                .frame(width: 38, height: 4)
                .frame(maxWidth: .infinity)
                .padding(.top, 10)
                .padding(.bottom, 16)

            Text(agent.name)
                .text(.rowName)
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.edge)

            Text(stateLine(agent))
                .text(.rowSubtitle)
                .foregroundStyle(agent.isBlocked ? Theme.sigLift : Theme.ink2)
                .padding(.horizontal, Theme.edge)
                .padding(.top, 4)

            if agent.capabilities.isEmpty {
                // Not an error and not an empty state to apologise for: this
                // daemon has not declared any controls, and inventing some
                // would be the exact failure the whole capability contract
                // exists to prevent.
                Text("archserver declares no controls for this agent.")
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink3)
                    .padding(Theme.edge)
            } else {
                VStack(spacing: 0) {
                    ForEach(agent.capabilities) { capability in
                        row(capability)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
                .padding(.top, 18)
            }

            if retasking { retaskForm }

            Color.clear.frame(height: 28)
        }
    }

    // MARK: - One capability

    @ViewBuilder
    private func row(_ capability: Capability) -> some View {
        Button {
            act(capability)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(capability.label)
                        .text(.rowName)
                        .foregroundStyle(tint(capability))
                    // Not help text -- the labels' subtitles, always visible.
                    // SERVER-PLAN 4 is explicit that the copy must not imply
                    // two strengths of the same thing.
                    if let sentence = subtitle(capability) {
                        Text(sentence)
                            .text(.rowSubtitle)
                            .foregroundStyle(Theme.ink3)
                            .multilineTextAlignment(.leading)
                    }
                    if !capability.usable, let refusal = capability.refusal {
                        Text(refusal)
                            .text(.label(9.5))
                            .foregroundStyle(Theme.ink3)
                            .padding(.top, 2)
                    }
                }
                Spacer(minLength: 8)
                if busy == capability.id {
                    Text("…")
                        .text(.cellValue)
                        .foregroundStyle(Theme.ink3)
                } else if !capability.usable {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            // Kill is the one control a tap cannot commit. It has to be held,
            // and the hold is the confirmation.
            if capability.id == "kill", capability.usable {
                HoldToFill(label: capability.label, act: onKill)
                    .padding(.horizontal, Theme.edge)
                    .padding(.bottom, 10)
            }
        }
    }

    private func act(_ capability: Capability) {
        guard capability.usable else {
            onDispatch(capability)         // surfaces the reason as a toast
            return
        }
        switch capability.id {
        case "kill":
            break                          // the hold commits it, never a tap
        case "retask":
            withAnimation(.enter) { retasking.toggle() }
        default:
            onDispatch(capability)
        }
    }

    private func tint(_ capability: Capability) -> Color {
        if !capability.usable { return Theme.ink3 }
        return capability.id == "kill" ? Theme.sig : Theme.ink
    }

    /// The asymmetry, in words, under both controls. Written here rather than
    /// taken from the server because it is a statement about what the two verbs
    /// mean, not about this agent -- and the server's `reason` field is for the
    /// per-agent half.
    private func subtitle(_ capability: Capability) -> String? {
        switch capability.id {
        case "stop": "Interrupts the current turn. The session survives and can take new work."
        case "kill": "Ends the session. It only comes back through Resume, and only if it left a handoff or a transcript."
        case "compact": "Interrupts, compacts the context, and continues. Reports what it actually did."
        case "retask": "Sends new instructions, optionally after stopping the current turn."
        case "resume": "Starts it again from its handoff or transcript."
        default: nil
        }
    }

    // MARK: - Retask

    /// One request, composed server-side. Two calls from a phone means a
    /// dropped network can leave an agent cancelled with nothing queued to
    /// replace it.
    private var retaskForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("What should it do instead?", text: $retaskText, axis: .vertical)
                .text(.body)
                .foregroundStyle(Theme.ink)
                .tint(Theme.sig)
                .lineLimit(1...4)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))

            // **Disabled and explained when `stop` is not enabled**, because the
            // server refuses `stop_first` rather than silently downgrading it,
            // and the app must not offer what will be refused.
            Toggle(isOn: $stopFirst) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stop the current turn first")
                        .text(.rowSubtitle)
                        .foregroundStyle(stoppable ? Theme.ink : Theme.ink3)
                    if !stoppable, let why = stopReason {
                        Text(why)
                            .text(.label(9.5))
                            .foregroundStyle(Theme.ink3)
                    }
                }
            }
            .disabled(!stoppable)
            .tint(Theme.sig)

            Button {
                let text = retaskText
                retaskText = ""
                withAnimation(.enter) { retasking = false }
                onRetask(text, stopFirst && stoppable)
            } label: {
                Text("SEND")
                    .text(.label(10))
                    .foregroundStyle(Theme.bg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.ink))
            }
            .buttonStyle(.plain)
            .disabled(retaskText.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(retaskText.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
        }
        .padding(Theme.edge)
    }

    private var stopCapability: Capability? {
        agent.capabilities.first { $0.id == "stop" }
    }

    private var stoppable: Bool { stopCapability?.usable ?? false }

    private var stopReason: String? {
        guard let stop = stopCapability else { return "archserver does not offer Stop here." }
        return stop.refusal
    }

    // MARK: - The grabber

    private func grabber(height: Double) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                onDrag(.move(clamp(progress - value.translation.height / max(height, 1), 0, 1)))
            }
            .onEnded { value in
                onDrag(.release(-value.velocity.height / max(height, 1)))
            }
    }
}

/// What the sheet's own recognizer tells `Shell`. Same shape as `ScrubPhase`,
/// and deliberately a separate type: two progress values that happen to share a
/// gesture vocabulary are still two progress values.
enum SheetPhase {
    case move(Double)
    /// Progress per second, already normalised against the sheet's height.
    case release(Double)
}

// MARK: - Hold to confirm

/// **The app's one confirmation component.** Kill uses it here; purge will use
/// the same one (APP-PLAN 9.5), which is the point of building it as a
/// component rather than as part of either.
///
/// - The fill is **linear over 1 500 ms, on purpose**: the bar is a clock, and
///   easing a clock makes it lie about how much time is left.
/// - The label is duplicated in the inverse colour and masked to the fill, so
///   it inverts *under* the sweeping boundary rather than the boundary sliding
///   over dead space.
/// - Cancel retracts from wherever it reached over 220 ms `.easeOut` -- a fast
///   asymmetric snap-back against the slow linear fill. **Nothing is sent and
///   no state changes until the timer completes.**
struct HoldToFill: View {
    let label: String
    let act: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fill: Double = 0
    @State private var holding = false
    @State private var halfway: Task<Void, Never>?
    @State private var budget = HapticBudget()
    @State private var press = 0

    private var duration: Double { reduceMotion ? 0.6 : 1.5 }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.sig20)
                Text("HOLD TO \(label.uppercased())")
                    .text(.label(10))
                    .foregroundStyle(Theme.sig)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 34)
            // The sweep and the inverted label are one `Animatable` modifier.
            // Writing `.frame(width: geo.size.width * fill)` directly would read
            // the *model* value, which `withAnimation` sets to its target
            // immediately -- so the bar would appear full on the first frame and
            // the whole confirmation would be a lie.
            .modifier(Sweep(fill: fill, width: geo.size.width, label: label))
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in begin() }
                    .onEnded { _ in cancel() }
            )
            .sensoryFeedback(.impact(weight: .light), trigger: press)
            .sensoryFeedback(.selection, trigger: budget.pulse)
        }
        .frame(height: 34)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(label). Hold to confirm.")
        .accessibilityAction { act() }
    }

    private func begin() {
        guard !holding else { return }
        holding = true
        press &+= 1
        halfway = Task {
            try? await Task.sleep(for: .seconds(duration / 2))
            guard !Task.isCancelled else { return }
            var copy = budget
            copy.fire()
            budget = copy
        }
        withAnimation(.linear(duration: duration), completionCriteria: .removed) {
            fill = 1
        } completion: {
            // A cancel sets `fill` back to 0 before this runs, so the guard is
            // what makes the whole hold reversible at any point.
            guard fill == 1 else { return }
            fill = 0
            holding = false
            act()
        }
    }

    private func cancel() {
        guard holding else { return }
        holding = false
        halfway?.cancel()
        halfway = nil
        withAnimation(.easeOut(duration: 0.22)) { fill = 0 }
    }
}

/// The sweeping boundary, as an `Animatable` modifier so SwiftUI interpolates
/// the fraction itself and re-evaluates `body` at each value.
private nonisolated struct Sweep: ViewModifier, Animatable {
    var fill: Double
    let width: Double
    let label: String

    var animatableData: Double {
        get { fill }
        set { fill = newValue }
    }

    @MainActor func body(content: Content) -> some View {
        content
            .overlay(alignment: .leading) {
                ZStack(alignment: .leading) {
                    Rectangle().fill(Theme.sig)
                    Text("HOLD TO \(label.uppercased())")
                        .text(.label(10))
                        .foregroundStyle(Theme.bg)
                        .frame(width: width)
                }
                .frame(width: max(0, width * fill), alignment: .leading)
                .clipped()
            }
            .clipShape(Capsule())
    }
}

/// The channel header's state line, and the control sheet's own. One function
/// so the two cannot drift apart -- he taps the first to reach the second.
nonisolated func stateLine(_ agent: Agent) -> String {
    switch agent.presence {
    case .blocked: "Waiting on you"
    case .busy: agent.isStalled ? "Running — nothing observed for a while" : "Running"
    case .live: "Idle"
    case .done: "Finished"
    case .dead: agent.deadReason ?? "Not running"
    }
}

// MARK: - Brief a new agent

/// The pull past the bottom of the fleet list, and the `new` capability from
/// `/health`'s `globalControls`.
///
/// **The gesture is never a dead end.** When archserver does not declare `new`,
/// or declares it disabled, this still opens and says so where the field would
/// have been -- a pull that bounces back silently is indistinguishable from a
/// pull the app did not notice.
struct BriefSheet: View {
    let capability: Capability?
    let progress: Double
    let busy: Bool
    let onDismiss: () -> Void
    let onSend: (String) -> Void
    let onDrag: (SheetPhase) -> Void

    @State private var task = ""

    private var offered: Bool { capability?.usable ?? false }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(0.55 * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                VStack(alignment: .leading, spacing: 14) {
                    Capsule()
                        .fill(Theme.line2)
                        .frame(width: 38, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10)

                    Text(capability?.label ?? "New agent")
                        .text(.rowName)
                        .foregroundStyle(Theme.ink)

                    if offered {
                        TextField("What should it do?", text: $task, axis: .vertical)
                            .text(.body)
                            .foregroundStyle(Theme.ink)
                            .tint(Theme.sig)
                            .lineLimit(2...6)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg))

                        Button {
                            let text = task
                            task = ""
                            onSend(text)
                        } label: {
                            Text(busy ? "…" : "BRIEF")
                                .text(.label(10))
                                .foregroundStyle(Theme.bg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(Capsule().fill(Theme.ink))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy || task.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(task.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    } else {
                        Text(capability?.refusal ?? "archserver does not offer briefing here.")
                            .text(.rowSubtitle)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .padding(.horizontal, Theme.edge)
                .padding(.bottom, 30)
                .frame(width: geo.size.width, alignment: .leading)
                .background(
                    UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                        .fill(Theme.surf)
                        .overlay(
                            UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                                .stroke(Theme.line, lineWidth: 1))
                        .ignoresSafeArea(edges: .bottom)
                )
                .offset(y: (1 - progress) * geo.size.height)
                .gesture(
                    DragGesture(minimumDistance: 6)
                        .onChanged { value in
                            onDrag(.move(clamp(progress - value.translation.height
                                               / max(geo.size.height, 1), 0, 1)))
                        }
                        .onEnded { value in
                            onDrag(.release(-value.velocity.height / max(geo.size.height, 1)))
                        }
                )
            }
        }
        .allowsHitTesting(progress > 0.5)
    }
}
