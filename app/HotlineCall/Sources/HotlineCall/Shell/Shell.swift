import SwiftUI

/// The whole app, as one `ZStack` of layers.
///
/// **There is no `NavigationStack`.** The list -> channel transition (step 3)
/// is not a push; it is an orchestrated disassembly driven by one `Double` that
/// a drag can scrub backwards and forwards at whatever speed the thumb chooses.
/// `NavigationStack` owns its own transition and its own interactive pop and
/// neither is reachable as a scalar we can read, so building on it would mean
/// building on a transition we cannot see, in a container that fights us for
/// the left-edge gesture.
///
/// The layer order is APP-PLAN 2.1's, and `Z` names every slot -- including
/// the ones whose views are later steps -- so adding one is a `zIndex(Z.map)`
/// and not a re-derivation of the stack.
struct Shell: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.scenePhase) private var scenePhase

    @State private var toast: Toast?
    @State private var refreshing = false
    @State private var settings = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            FleetLayer(fleet: fleet, reachable: fleet.reachable,
                       refreshing: refreshing, onSettings: { settings = true })
                .zIndex(Z.fleet)

            OverlayLayer(reachable: fleet.reachable, toast: toast)
                .zIndex(Z.overlay)
        }
        .coordinateSpace(name: Space.shell)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsSheet() }
        .task { await launch() }
        // The only thing that starts or stops the roster stream is the app
        // becoming, or ceasing to be, active. This is the first half of bug 1:
        // the old app refreshed from `.task` and `.refreshable` only, and
        // `.task` fires once per store identity -- which is stable for the
        // whole foregrounded lifetime, so the list went stale on launch and
        // stayed stale.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { fleet.begin() } else { fleet.suspend() }
        }
        .onChange(of: toast?.id) { _, _ in expireToast() }
    }

    private func launch() async {
        refreshing = true
        await fleet.hardRefresh()
        refreshing = false
        fleet.begin()
    }

    private func expireToast() {
        guard let current = toast else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if toast?.id == current.id { toast = nil }
        }
    }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
}
