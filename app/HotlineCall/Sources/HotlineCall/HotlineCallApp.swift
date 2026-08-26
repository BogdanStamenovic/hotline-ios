import SwiftUI

@main
struct HotlineApp: App {
    @State private var server = Server()

    init() {
        // Register the bundled faces before the first `body` asks for a glyph.
        // Doing it lazily would work -- Swift statics are lazy and atomic --
        // but it would do file I/O inside a view evaluation on the first frame.
        _ = Fonts.registered
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(server)
        }
    }
}

/// Sits above everything so the app has somewhere to go when it does not yet
/// know where the server is. A `Fleet` cannot be built without a URL, and
/// building one against a guess would fail as a timeout -- which looks exactly
/// like archserver being down.
///
/// `.id(url)` tears down and rebuilds the whole store when the address changes,
/// rather than leaving half of it pointed at the old host.
private struct RootView: View {
    @Environment(Server.self) private var server

    var body: some View {
        if let url = server.url {
            ShellHost(url: url).id(url)
        } else {
            SetupView()
        }
    }
}

/// The store lives in `@State`, not in `RootView.body`.
///
/// Building it inline would construct a fresh `Fleet` -- and with it a fresh
/// roster stream and a fresh roster -- on every re-evaluation of the parent's
/// body. `.id(url)` gives the *view* a stable identity; only `@State` gives the
/// object one.
private struct ShellHost: View {
    let url: URL
    @State private var fleet: Fleet

    init(url: URL) {
        self.url = url
        _fleet = State(initialValue: Fleet(link: Link(base: url)))
    }

    var body: some View {
        Shell().environment(fleet)
    }
}

private struct SetupView: View {
    @Environment(Server.self) private var server
    @State private var typed = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("100.x.y.z or archserver", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                } header: {
                    Text("archserver")
                } footer: {
                    Text("Its Tailscale address. Port 8789 is assumed. "
                         + "Nothing here leaves your tailnet.")
                }
                Button("Connect") { server.address = typed }
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("Hotline")
        }
        .preferredColorScheme(.dark)
    }
}

/// The one system `.sheet` in the app. Settings is a standard `Form` where the
/// platform's presentation is the right thing and no motion continuity is
/// claimed; everything that participates in the motion language is a custom
/// layer instead.
///
/// It exists because without it a typo in the address strands him on a screen
/// that only ever times out, with no way back to the one setting that fixes it.
struct SettingsSheet: View {
    @Environment(Server.self) private var server
    @Environment(\.dismiss) private var dismiss
    /// Whether any open session reports its context use. It decides one
    /// sentence, and that sentence is the whole reason APP-PLAN 5.6 asked the
    /// server for a boolean.
    let contextReported: Bool
    let onFreeUpSpace: () async -> Void
    let onMeasure: () async -> Int

    @State private var typed = ""
    @State private var bytes: Int?
    @State private var clearing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("archserver") {
                    TextField("100.x.y.z or archserver", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                // **Nowhere near the purge control, and in ordinary ink rather
                // than `sig`, because it is not destruction.** The label says
                // what it does in its own words.
                Section {
                    Button {
                        clearing = true
                        Task {
                            await onFreeUpSpace()
                            bytes = await onMeasure()
                            clearing = false
                        }
                    } label: {
                        HStack {
                            Text("Free up space")
                            Spacer()
                            Text(clearing ? "…" : (bytes.map(bytesLabel) ?? "—"))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(clearing || (bytes ?? 0) == 0)
                } header: {
                    Text("This phone")
                } footer: {
                    Text("Clears the copy on this phone. Nothing on archserver is deleted; "
                         + "the app re-downloads what it needs.")
                }

                Section {
                    if !contextReported {
                        // The permanent case, said once, in words. Without it an
                        // absent gauge is indistinguishable from a broken one.
                        Text("Context use: not reported for this session.")
                    } else {
                        Text("Context use: reported.")
                    }
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("The context gauge needs hotline's statusLine wrapper installed for a "
                         + "session. When it is not, the strip lays out with three cells and no "
                         + "bar — the reading is missing, not zero.")
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
            .task { bytes = await onMeasure() }
        }
    }
}
