import SwiftUI

/// One agent, as Kinetic Prime draws it.
///
/// **No telemetry of any kind lives here.** No rail, no sparkline, no
/// tool-call flash, no host chip. Bogdan scoped Telemetry's readouts to the
/// inside of a channel on 2026-08-26 (APP-PLAN 5.0), and if a future change
/// wants a number on a list row it starts from that line rather than from an
/// inference off this file.
struct FleetRow: View {
    let agent: Agent
    let height: Double
    let isHero: Bool
    let swipeX: Double
    /// `nav` and `mo`, so the name's hand-off to the travelling copy is a term
    /// in the staging table rather than a comparison against a model value
    /// that jumps to its target the instant the transition starts.
    let nav: Double
    let mo: Double
    @Binding var titleFrame: [AgentID: CGRect]
    let onControl: (Capability) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            controls
            face
                .offset(x: swipeX)
        }
        .frame(height: height, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityAddTraits(.isButton)
        // Every capability is reachable without the swipe. The swipe is the
        // fast path, never the only one.
        .accessibilityActions {
            ForEach(agent.capabilities) { capability in
                Button(capability.label) { onControl(capability) }
            }
        }
    }

    // MARK: - The row itself

    private var face: some View {
        ZStack(alignment: .topLeading) {
            Theme.bg

            if agent.isBlocked {
                LinearGradient(colors: [Theme.sig10, .clear],
                               startPoint: .leading, endPoint: .trailing)
                Rectangle()
                    .fill(Theme.sig)
                    .frame(width: 2)
            }

            HStack(alignment: .top, spacing: 14) {
                StatusDot(presence: agent.presence)
                    .padding(.top, 3)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(agent.name)
                            .text(.rowName)
                            .foregroundStyle(Theme.ink)
                            .staged(.heroName, isHero ? nav : 0, mo)
                            // Measured in the list's own untransformed space,
                            // so the rect is right whatever the fleet layer is
                            // doing to itself mid-transition. Re-measured on
                            // every change because the row moves: reorder,
                            // unpin, scroll.
                            .onGeometryChange(for: CGRect.self) { proxy in
                                proxy.frame(in: .named(Space.list))
                            } action: { rect in
                                titleFrame[agent.name] = rect
                            }
                        if agent.isBlocked {
                            Text("NEEDS YOU")
                                .text(.label(9.5))
                                .foregroundStyle(Theme.sig)
                        }
                        if agent.isStalled {
                            Text("STALLED")
                                .text(.label(9.5))
                                .foregroundStyle(Theme.ink3)
                        }
                    }
                    Text(subtitle)
                        .text(.rowSubtitle)
                        .foregroundStyle(agent.isBlocked ? Theme.sigLift : Theme.ink2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)
                stamp
            }
            .padding(.horizontal, Theme.edge)
            .padding(.top, 26)

            VStack {
                Spacer()
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }

    /// A ticking clock, and only where there is one to tick. The list is quiet
    /// for up to 25 s between roster wakes, so a stamp computed once at render
    /// would freeze; the periodic schedule is scoped to this label alone so the
    /// rest of the row is not re-evaluated with it.
    @ViewBuilder
    private var stamp: some View {
        if let at = agent.stamp {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(ago(at, now: context.date))
                    .text(.label(11))
                    .monospacedDigit()
                    .foregroundStyle(agent.isBlocked ? Theme.sig : Theme.ink3)
            }
        }
    }

    /// The newest event's text is a `Channel` fact and channels are step 4, so
    /// until then the row says the truest thing the roster itself carries: why
    /// it died, or what it was told to do. Nothing here is synthesised.
    private var subtitle: String {
        if agent.presence == .dead, let reason = agent.deadReason { return reason }
        return agent.task
    }

    private var spokenLabel: String {
        var parts = [agent.name]
        switch agent.presence {
        case .blocked:
            if let at = agent.blockedAt {
                parts.append("blocked \(spokenAgo(at))")
            } else {
                parts.append("blocked")
            }
            parts.append("needs you")
        case .busy: parts.append("working")
        case .live: parts.append("idle")
        // Spoken apart for the same reason they are drawn apart: one of these
        // finished, the other stopped existing.
        case .done: parts.append("finished")
        case .dead: parts.append(agent.deadReason ?? "not running")
        }
        parts.append(subtitle)
        return parts.joined(separator: ", ")
    }

    // MARK: - The revealed controls
    //
    // Rendered from the server's array, in the server's order, with the
    // server's labels. A capability this build cannot dispatch is shown
    // disabled rather than hidden: hiding it makes a server that has moved
    // ahead of the app invisible, and needing a new build is the one thing
    // that is expensive to discover any other way.

    private var controls: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(rightControl.map { [$0] } ?? []) { capability in
                    ControlPad(capability: capability, tint: Theme.line2) {
                        onControl(capability)
                    }
                    .frame(width: 118)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                ForEach(leftControls) { capability in
                    ControlPad(capability: capability,
                               tint: capability.id == "kill" ? Theme.sig20 : Theme.line2) {
                        onControl(capability)
                    }
                    .frame(width: leftControls.count > 1 ? 74 : 148)
                }
            }
        }
        .frame(height: height)
        .background(Theme.surf)
    }

    private var leftControls: [Capability] {
        agent.capabilities.filter { $0.id == "stop" || $0.id == "kill" }.prefix(2).map { $0 }
    }

    private var rightControl: Capability? {
        agent.capabilities.first { $0.id == "retask" }
            ?? agent.capabilities.first { $0.id == "resume" }
    }
}

/// One revealed control. Disabled renders visible and dimmed and still answers
/// a tap -- with its reason. A disabled control that does nothing when tapped
/// is indistinguishable from a broken one.
private struct ControlPad: View {
    let capability: Capability
    let tint: Color
    let act: () -> Void

    var body: some View {
        Button(action: act) {
            VStack(spacing: 5) {
                Text(capability.label.uppercased())
                    .text(.label(10))
                    .multilineTextAlignment(.center)
                if !capability.usable {
                    Image(systemName: "slash.circle")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundStyle(capability.usable ? Theme.ink : Theme.ink3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(tint.opacity(capability.usable ? 1 : 0.4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - The status dot

/// APP-PLAN 5.1. **The pulse is a categorical encoding, not a quantity**:
/// which rate you see tells you which state the agent is in, and that mapping
/// is real data. It does not claim to be a rate of anything.
///
/// A finished agent is still -- no pulse, no ring, no breathe. SERVER-PLAN 9.2
/// states that as a correctness requirement on the data rather than a styling
/// note, so it is enforced in the mark itself.
///
/// **Five states, not four** (APP-PLAN 12.5), and `done` and `dead` are told
/// apart without a fifth hue -- which would fight the single-accent discipline
/// the whole design rests on:
///
/// | state | fill | motion |
/// |---|---|---|
/// | live | solid ink | 3.6 s breathe |
/// | busy | ink 42 % | 1.15 s breathe, expanding ring |
/// | blocked | `sig` | 1.7 s breathe, expanding ring |
/// | **done** | **solid, dimmed** | **still** |
/// | **dead** | **hollow ring** | **still** |
///
/// Filled-but-quiet is an agent that finished and said so; an empty ring is a
/// process that is gone. Same restraint, one more true thing per glance.
struct StatusDot: View {
    let presence: Agent.Presence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathing = false
    @State private var ringing = false

    var body: some View {
        ZStack {
            if hasRing {
                Circle()
                    .stroke(color, lineWidth: 1.2)
                    .frame(width: 8, height: 8)
                    .scaleEffect(ringing ? 2.4 : 1)
                    .opacity(ringing ? 0 : 0.7)
            }
            // The one hollow mark in the app. Nothing inside it, because
            // there is nothing running.
            if presence == .dead {
                Circle()
                    .stroke(Theme.ink3, lineWidth: 1.4)
                    .frame(width: 8, height: 8)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .opacity(breathing ? 1 : dim)
            }
        }
        .frame(width: 10, height: 10)
        .animation(loop, value: breathing)
        .animation(ringLoop, value: ringing)
        .onAppear(perform: start)
        .onChange(of: presence) { _, _ in start() }
        .accessibilityHidden(true)
    }

    private func start() {
        // Looping decoration stops entirely under Reduce Motion, and an agent
        // that has stopped never starts one at all.
        guard !reduceMotion, period > 0 else {
            breathing = false
            ringing = false
            return
        }
        breathing = true
        ringing = true
    }

    private var hasRing: Bool { presence == .busy || presence == .blocked }

    private var color: Color {
        switch presence {
        case .blocked: Theme.sig
        case .busy: Theme.ink.opacity(0.42)
        case .live: Theme.ink
        // Filled, but quiet: it finished and said so.
        case .done: Theme.ink3
        case .dead: Theme.ink3
        }
    }

    private var dim: Double {
        switch presence {
        case .blocked: 0.35
        case .busy: 0.30
        case .live: 0.45
        case .done, .dead: 1
        }
    }

    private var period: Double {
        switch presence {
        case .live: 3.6
        case .busy: 1.15
        case .blocked: 1.7
        case .done, .dead: 0
        }
    }

    private var loop: Animation? {
        guard period > 0, !reduceMotion else { return nil }
        return .easeInOut(duration: period / 2).repeatForever(autoreverses: true)
    }

    private var ringLoop: Animation? {
        guard hasRing, !reduceMotion else { return nil }
        return .easeOut(duration: period).repeatForever(autoreverses: false)
    }
}

// MARK: - Relative time

/// Short, tabular, and never rounded up into a lie. Under a minute reads
/// "now" because a second-resolution clock on a list that wakes every 25 s
/// would be precision the data does not have.
nonisolated func ago(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "now"
    case ..<3600: return "\(Int(seconds / 60))m"
    case ..<86400: return "\(Int(seconds / 3600))h"
    default: return "\(Int(seconds / 86400))d"
    }
}

nonisolated func spokenAgo(_ date: Date, now: Date = .now) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    switch seconds {
    case ..<60: return "just now"
    case ..<3600:
        let m = Int(seconds / 60)
        return "\(m) minute\(m == 1 ? "" : "s")"
    case ..<86400:
        let h = Int(seconds / 3600)
        return "\(h) hour\(h == 1 ? "" : "s")"
    default:
        let d = Int(seconds / 86400)
        return "\(d) day\(d == 1 ? "" : "s")"
    }
}
