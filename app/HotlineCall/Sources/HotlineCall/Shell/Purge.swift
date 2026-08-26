import SwiftUI

/// Deletion (APP-PLAN 8.2). **Irreversible, and it looks it.**
///
/// The flow, in order, and every step of it exists to make one thing true: the
/// number is the consent.
///
/// 1. a scope, and optionally a `before_seq` handed in from the map's cursor;
/// 2. the call with `dry_run: true`;
/// 3. **the sheet is built from the real counts the server returned** -- never a
///    generic warning;
/// 4. hold to confirm, on the same 1 500 ms component the kill control uses;
/// 5. if the sheet has been open more than ten seconds, **re-run the dry run
///    before the destructive call** -- consenting to stale counts is not
///    consent -- and if the counts moved, show the new ones and make him hold
///    again;
/// 6. the slam card, with `DELETED` and the counts as its sub-line.
struct PurgeSheet: View {
    let agent: Agent
    let progress: Double
    /// A finger is on this seam; see `Shell`'s `sheetDragging` and `SeamDrag`.
    let dragging: Bool
    /// From the map's cursor, when he came in through "delete everything before
    /// here". `nil` is the whole history.
    let beforeSeq: Int?
    let onDismiss: () -> Void
    let onDrag: (SheetPhase) -> Void
    /// Runs the call with `dry_run: true` and hands back what archserver said.
    let dryRun: (String, Int?) async -> Fleet.Attempt<PurgeCounts>
    /// The destructive call. Only ever reached through the hold, and only with
    /// counts he has just been shown.
    let commit: (String, Int?, PurgeCounts) -> Void

    @State private var scope = "history"
    @State private var counts: PurgeCounts?
    @State private var shownAt: Date?
    @State private var failure: String?
    @State private var rechecking = false
    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                Color.black
                    .opacity(0.55 * progress)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { onDismiss() }

                panel
                    .frame(width: geo.size.width, alignment: .leading)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                            .fill(Theme.surf)
                            .overlay(
                                UnevenRoundedRectangle(topLeadingRadius: 22, topTrailingRadius: 22)
                                    .stroke(Theme.sig20, lineWidth: 1))
                            .ignoresSafeArea(edges: .bottom)
                    )
                    .offset(y: (1 - progress) * geo.size.height)
                    .seamDrag(progress: progress,
                              delta: { -$0.height / max(geo.size.height, 1) },
                              rate: { -$0.height / max(geo.size.height, 1) },
                              phase: onDrag)
            }
        }
        .allowsHitTesting(progress > 0.5 || dragging)
        .task(id: scope) { await recount() }
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

            scopePicker
                .padding(.horizontal, Theme.edge)
                .padding(.top, 14)

            if let beforeSeq {
                Text("Only what came before event \(beforeSeq), from the route cursor.")
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
                    .padding(.horizontal, Theme.edge)
                    .padding(.top, 10)
            }

            body(for: counts)
                .padding(.horizontal, Theme.edge)
                .padding(.top, 16)

            Color.clear.frame(height: 30)
        }
    }

    /// `history` keeps the agent and drops what it did; `everything` also drops
    /// the agent record. Two scopes, not five.
    private var scopePicker: some View {
        HStack(spacing: 8) {
            ForEach(["history", "everything"], id: \.self) { option in
                Button {
                    guard scope != option else { return }
                    scope = option
                } label: {
                    Text(option.uppercased())
                        .text(.label(10))
                        .foregroundStyle(scope == option ? Theme.bg : Theme.ink2)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(scope == option ? Theme.ink : Theme.line2))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func body(for counts: PurgeCounts?) -> some View {
        if let failure {
            Text(failure)
                .text(.rowSubtitle)
                .foregroundStyle(Theme.sig)
        } else if let counts {
            VStack(alignment: .leading, spacing: 8) {
                Text(purgeSentence(counts))
                    .text(.cellValue)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                if let oldest = counts.oldestDate {
                    Text("oldest \(oldest.formatted(.dateTime.day().month(.abbreviated)))")
                        .text(.rowSubtitle)
                        .foregroundStyle(Theme.ink3)
                }
                Text(scope == "everything"
                     ? "This deletes them on archserver, and drops the agent record too. It cannot be undone."
                     : "This deletes them on archserver. It cannot be undone.")
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink2)

                if moved {
                    // The counts he was shown are not the counts any more.
                    Text("archserver's numbers moved while this was open. These are the new ones.")
                        .text(.label(9.5))
                        .foregroundStyle(Theme.sig)
                }

                if counts.total > 0 {
                    HoldToFill(label: "Delete") { hold(counts) }
                        .padding(.top, 6)
                        .opacity(rechecking ? 0.4 : 1)
                        .disabled(rechecking)
                } else {
                    // Nothing to destroy, so no confirmation to perform.
                    Text("Nothing to delete.")
                        .text(.rowSubtitle)
                        .foregroundStyle(Theme.ink3)
                }
            }
        } else {
            Text("Asking archserver what this would delete…")
                .text(.rowSubtitle)
                .foregroundStyle(Theme.ink3)
        }
    }

    private func recount() async {
        failure = nil
        moved = false
        switch await dryRun(scope, beforeSeq) {
        case .ok(let fresh):
            counts = fresh
            shownAt = .now
        case .failed(let why):
            failure = why
        }
    }

    /// Step 5. The re-run is not a formality: a purge is only ever performed
    /// against numbers he has looked at within the last ten seconds.
    private func hold(_ shown: PurgeCounts) {
        guard let shownAt else { return }
        guard Date.now.timeIntervalSince(shownAt) > 10 else {
            commit(scope, beforeSeq, shown)
            return
        }
        rechecking = true
        Task {
            defer { rechecking = false }
            switch await dryRun(scope, beforeSeq) {
            case .ok(let fresh):
                counts = fresh
                self.shownAt = .now
                guard sameConsent(shown, fresh) else {
                    // He agreed to a different number. Make him agree again.
                    withAnimation(.enter) { moved = true }
                    return
                }
                commit(scope, beforeSeq, fresh)
            case .failed(let why):
                failure = why
            }
        }
    }
}
