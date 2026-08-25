import SwiftUI

/// One agent's screen. Everything in it is a pure function of `nav`.
///
/// The transcript, the feed and the composer's `pending` reconciliation are
/// step 4 and are deliberately absent: this layer exists at step 3 so the scene
/// change has a real destination to assemble, with every element on its own
/// window from APP-PLAN 4.3's staging table.
struct ChannelLayer: View {
    let agent: Agent
    let nav: Double
    let mo: Double
    let onBack: () -> Void
    let onDrag: (ScrubPhase) -> Void

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Theme.bg.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    header
                    thread
                    ChannelComposer()
                        .staged(.composer, nav, mo)
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
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The hero's destination. Its opacity is a hard swap at e > 0.88,
            // where the travelling copy hides -- one object arriving, not two
            // labels crossfading.
            Text(agent.name)
                .text(.screenTitle)
                .foregroundStyle(Theme.ink)
                // 98 pt is the hero's destination; the travelling copy and
                // this label must agree to the point or the handover at
                // e > 0.88 shows as a jump.
                .staged(.headerTitle, nav, mo)
                .frame(height: 34, alignment: .leading)
                .padding(.top, HeroDestination.y)

            Rectangle()
                .fill(Theme.sig)
                .frame(width: 120, height: 2)
                .staged(.accentRule, nav, mo)
                .padding(.top, 10)

            HStack(spacing: 10) {
                PhaseChip()
                    .staged(.phaseChip, nav, mo)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)

            Text(stateLine)
                .text(.rowSubtitle)
                .foregroundStyle(agent.isBlocked ? Theme.sigLift : Theme.ink2)
                .staged(.stateLine, nav, mo)
                .padding(.top, 10)

            InstrumentStrip(agent: agent, nav: nav, mo: mo)
                .padding(.top, 16)

            Rectangle().fill(Theme.line).frame(height: 1).padding(.top, 18)
        }
        .padding(.leading, HeroDestination.x)
        .padding(.trailing, Theme.edge)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Real, from the roster. The one thing on this screen that is a fact about
    /// the agent rather than a fact about the transition.
    private var stateLine: String {
        switch agent.presence {
        case .blocked: "Waiting on you"
        case .busy: agent.isStalled ? "Running — nothing observed for a while" : "Running"
        case .live: "Idle"
        case .dead: agent.deadReason ?? "Not running"
        }
    }

    // MARK: - Thread

    /// Empty, because nothing has fetched a transcript: `Channel`, the cache
    /// and the hard-refresh-then-stream seam are step 4. The staging window for
    /// message `k` is implemented in `Role.message` and applied here the moment
    /// there are moments to apply it to.
    private var thread: some View {
        VStack {
            Spacer()
            Text("No transcript loaded.")
                .text(.rowSubtitle)
                .foregroundStyle(Theme.ink3)
                .staged(.message(k: 0), nav, mo)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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

private struct PhaseChip: View {
    var body: some View {
        Text("ROUTE")
            .text(.label(9.5))
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(Capsule().stroke(Theme.line2, lineWidth: 1))
    }
}

/// APP-PLAN 5.3's four cells, rendering **only the ones with a source**.
///
/// `Vitals` is absent until server step 8 and `declaredAt` until APP-PLAN 11's
/// first ask lands, so today this is usually empty and that is correct. A cell
/// with no honest source does not ship, and a strip of dashes is a readout
/// claiming to be a measurement.
private struct InstrumentStrip: View {
    let agent: Agent
    let nav: Double
    let mo: Double

    var body: some View {
        if !cells.isEmpty {
            HStack(alignment: .top, spacing: 26) {
                ForEach(Array(cells.enumerated()), id: \.element.label) { index, cell in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(cell.label)
                            .text(.label(9.5))
                            .foregroundStyle(Theme.ink3)
                        Text(cell.value)
                            .text(.cellValue)
                            .monospacedDigit()
                            .foregroundStyle(cell.hot ? Theme.sig : Theme.ink)
                            .contentTransition(.numericText())
                    }
                    .staged(.stripCell(index), nav, mo)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private struct Cell {
        let label: String
        let value: String
        var hot = false
    }

    private var cells: [Cell] {
        var out: [Cell] = []
        if let vitals = agent.vitals {
            // Characters, not a tokenizer count, and never a billing figure.
            out.append(Cell(label: "OUTPUT", value: "\(Int(vitals.tokensPerSec.rounded())) ch/s"))
            if let used = vitals.contextUsed {
                out.append(Cell(label: "CONTEXT", value: "\(Int((used * 100).rounded())) %",
                                hot: used > 0.85))
            } else if agent.contextAvailable ?? true {
                // The session has not taken its first turn. An empty track that
                // will fill in thirty seconds and one that never will look
                // identical and mean opposite things, which is why the third
                // state renders nothing at all rather than a dash.
                out.append(Cell(label: "CONTEXT", value: "—"))
            }
            out.append(Cell(label: "TOOLS",
                            value: String(format: "%.1f /min", vitals.toolsPerMin)))
        }
        if agent.isBlocked, let since = agent.blockedAt {
            out.append(Cell(label: "BLOCKED", value: clock(-since.timeIntervalSinceNow), hot: true))
        } else if let declared = agent.declaredDate {
            out.append(Cell(label: "ELAPSED", value: clock(-declared.timeIntervalSinceNow)))
        }
        return out
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Present, and honestly refused. Sending needs `Channel.pending` -- the
/// optimistic echo that is never put in `moments` -- and that is step 4. This
/// renders the surface with the app's own vocabulary for a control it cannot
/// yet dispatch, rather than offering a field that silently drops what he
/// types.
private struct ChannelComposer: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("this build can't do that yet.")
                .text(.rowSubtitle)
                .foregroundStyle(Theme.ink3)
            Spacer(minLength: 0)
            Circle()
                .fill(Theme.ink5)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.ink4)
                )
        }
        .padding(.horizontal, Theme.edge)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.surf)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.line, lineWidth: 1))
        )
        .padding(.horizontal, Theme.edge)
        .padding(.bottom, 12)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Composer. Sending is not in this build yet.")
    }
}
