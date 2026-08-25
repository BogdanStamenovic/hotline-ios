import SwiftUI

struct ContentView: View {
    @Environment(CallCenter.self) private var center

    var body: some View {
        NavigationStack {
            Group {
                switch center.phase {
                case .idle, .ended:
                    Idle(phase: center.phase)
                case .ringing(let who, let reason):
                    Ringing(who: who, reason: reason)
                case .connected:
                    InCall()
                }
            }
            .navigationTitle("Hotline")
        }
    }
}

private struct Idle: View {
    let phase: CallPhase

    var body: some View {
        ContentUnavailableView {
            Label("No call", systemImage: "phone.down")
        } description: {
            if case .ended(let reason) = phase {
                Text("Last call \(reason).")
            } else {
                Text("A session will ring you when it needs you.")
            }
        }
    }
}

private struct Ringing: View {
    let who: String
    let reason: String

    var body: some View {
        VStack(spacing: 16) {
            Text(who).font(.largeTitle.bold())
            Text(reason).font(.body).multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

/// The in-call screen.
///
/// The thing worth getting right here is the tool line. hotline already
/// narrates tool calls aloud during long waits, and speech is serial -- it can
/// only say one thing at a time and has to be throttled not to talk over the
/// answer. A screen has neither constraint, so it shows every tool event as it
/// lands. That is the whole reason the server emits them to both.
private struct InCall: View {
    @Environment(CallCenter.self) private var center

    var body: some View {
        VStack(spacing: 0) {
            if let tool = center.currentTool {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tool).font(.footnote.monospaced()).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal).padding(.vertical, 8)
                .background(.thinMaterial)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollViewReader { proxy in
                List(center.moments) { moment in
                    Line(moment: moment).id(moment.id)
                }
                .listStyle(.plain)
                .onChange(of: center.moments.count) {
                    guard let last = center.moments.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            Button(role: .destructive) {
                center.hangUp()
            } label: {
                Label("Hang up", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding()
        }
        .animation(.snappy, value: center.currentTool)
    }
}

private struct Line: View {
    let moment: Moment

    var body: some View {
        switch moment.kind {
        case .tool, .summary:
            Label(moment.text, systemImage: "wrench.and.screwdriver")
                .font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(moment.text, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        case .state:
            Text(moment.text).font(.caption2).foregroundStyle(.tertiary)
        case .heard, .said:
            VStack(alignment: moment.isFromHim ? .trailing : .leading, spacing: 2) {
                Text(moment.isFromHim ? "you" : "claude")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(moment.text)
            }
            .frame(maxWidth: .infinity, alignment: moment.isFromHim ? .trailing : .leading)
        }
    }
}
