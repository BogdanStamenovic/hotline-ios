import SwiftUI

@main
struct HotlineApp: App {
    // archserver over Tailscale. Telegram rings the phone; from the moment this
    // opens, nothing in the path touches a cloud.
    @State private var store = Store(
        link: Link(base: URL(string: "http://100.72.2.62:8789")!))

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
        }
    }
}
