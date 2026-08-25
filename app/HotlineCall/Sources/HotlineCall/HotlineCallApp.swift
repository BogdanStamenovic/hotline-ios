import SwiftUI

@main
struct HotlineCallApp: App {
    // archserver over Tailscale. Everything after the ring goes here directly
    // and touches no cloud.
    @State private var center = CallCenter(
        link: Link(base: URL(string: "http://100.72.2.62:8789")!))

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(center)
        }
    }
}
