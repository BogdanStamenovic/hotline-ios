import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Environment(Server.self) private var server
    @State private var draft = ""
    @State private var changingServer = false
    @FocusState private var writing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.waiting.isEmpty, store.answering == nil {
                    WaitingBanner()
                }
                AgentBar()
                if let tool = store.currentTool {
                    ToolLine(tool: tool)
                }
                Transcript()
                Composer(draft: $draft, writing: $writing)
            }
            .navigationTitle("Hotline")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Without this a typo in the address strands him: the app would
                // sit on a screen that only ever times out, with no way back to
                // the one setting that fixes it.
                ToolbarItem(placement: .topBarTrailing) {
                    Button { changingServer = true } label: {
                        Image(systemName: "server.rack")
                    }
                }
            }
            .sheet(isPresented: $changingServer) { ServerSheet() }
            .task { await store.refresh() }
            .refreshable { await store.refresh() }
            .animation(.snappy, value: store.currentTool)
        }
    }
}

private struct ServerSheet: View {
    @Environment(Server.self) private var server
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("archserver") {
                    TextField("100.x.y.z or archserver", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }
            }
            .navigationTitle("Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { server.address = typed; dismiss() }
                        .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { typed = server.address }
        }
    }
}

/// Questions an agent is blocked on.
///
/// This is what the ring was for. It sits above everything else because a
/// blocked agent is the one thing in the app with someone waiting on the other
/// end of it.
private struct WaitingBanner: View {
    @Environment(Store.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            ForEach(store.waiting) { question in
                Button { store.answer(question) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "bell.badge.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(question.asked).font(.subheadline).multilineTextAlignment(.leading)
                            Text("waiting on you — \(question.at, style: .relative)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .background(.yellow.opacity(0.12))
    }
}

/// Who he is talking to, and who else is alive.
private struct AgentBar: View {
    @Environment(Store.self) private var store

    var body: some View {
        @Bindable var store = store
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                Chip(title: "newest", live: true, busy: false,
                     selected: store.chosen == nil) { store.chosen = nil }
                ForEach(store.agents) { agent in
                    Chip(title: agent.name, live: agent.live, busy: agent.busy,
                         selected: store.chosen == agent.name) { store.chosen = agent.name }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .background(.thinMaterial)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct Chip: View {
    let title: String
    let live: Bool
    let busy: Bool
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: 5) {
                Circle()
                    .fill(busy ? .orange : (live ? .green : .secondary))
                    .frame(width: 7, height: 7)
                Text(title).font(.footnote.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(selected ? AnyShapeStyle(.tint.opacity(0.18))
                                 : AnyShapeStyle(.quaternary),
                        in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

/// What the agent is doing right now.
///
/// This is the feature worth getting right. hotline narrates tool calls aloud
/// during long waits because dead air is the real problem; a screen has none of
/// speech's constraints, so it shows every one as it lands.
private struct ToolLine: View {
    let tool: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(tool).font(.footnote.monospaced()).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal).padding(.vertical, 7)
        .background(.thinMaterial)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct Transcript: View {
    @Environment(Store.self) private var store

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.moments) { moment in
                        Line(moment: moment).id(moment.id)
                    }
                }
                .padding()
            }
            .onChange(of: store.moments.count) {
                guard let last = store.moments.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .overlay {
                if store.moments.isEmpty {
                    ContentUnavailableView(
                        "Nothing yet", systemImage: "text.bubble",
                        description: Text("Give a session something to do."))
                }
            }
        }
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
        case .you, .claude:
            VStack(alignment: moment.isFromHim ? .trailing : .leading, spacing: 3) {
                Text(moment.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(moment.isFromHim ? AnyShapeStyle(.tint.opacity(0.16))
                                                 : AnyShapeStyle(.quaternary),
                                in: .rect(cornerRadius: 14))
                Text(moment.at, style: .time)
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: moment.isFromHim ? .trailing : .leading)
        }
    }
}

private struct Composer: View {
    @Environment(Store.self) private var store
    @Binding var draft: String
    @FocusState.Binding var writing: Bool

    private var busy: Bool {
        switch store.delivery {
        case .sending, .working: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            if let answering = store.answering {
                // He must be able to see WHICH question he is answering, or a
                // reply can land against the wrong blocked agent.
                Label("Answering: \(answering.asked)", systemImage: "arrowshape.turn.up.left")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(let why) = store.delivery {
                Label(why, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 8) {
                TextField(store.answering == nil
                            ? "Tell \(store.chosen ?? "the newest session")…"
                            : "Answer…",
                          text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($writing)
                    .submitLabel(.send)
                Button {
                    let text = draft
                    draft = ""
                    // The send is a Task, but clearing the field is synchronous
                    // and on the same frame as the tap -- otherwise the text
                    // lingers for a round trip and reads as a dropped input.
                    Task { await store.send(text) }
                } label: {
                    Image(systemName: busy ? "hourglass" : "arrow.up.circle.fill")
                        .font(.title2)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            }
        }
        .padding(.horizontal).padding(.vertical, 8)
        .background(.bar)
    }
}
