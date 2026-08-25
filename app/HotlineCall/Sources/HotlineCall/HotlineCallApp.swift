import SwiftUI

@main
struct HotlineApp: App {
    @State private var server = Server()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(server)
        }
    }
}

/// Sits above everything so the app has somewhere to go when it does not yet
/// know where the server is. A `Store` cannot be built without a URL, and
/// building one against a guess would fail as a timeout — which looks exactly
/// like archserver being down.
private struct RootView: View {
    @Environment(Server.self) private var server

    var body: some View {
        if let url = server.url {
            ContentView()
                .environment(Store(link: Link(base: url)))
                .id(url)   // rebuild the store if he changes the address
        } else {
            SetupView()
        }
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
    }
}
