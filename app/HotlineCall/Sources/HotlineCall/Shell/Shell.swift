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
/// What that gives up, stated so nobody rediscovers it as a bug: the system
/// back swipe, large-title behaviour, `NavigationPath` restoration, and
/// automatic keyboard avoidance in the pushed view. The first three are things
/// this app does not want.
///
/// The layer order is APP-PLAN 2.1's, and `Z` names every slot -- including
/// the ones whose views are later steps -- so adding one is a `zIndex(Z.map)`
/// and not a re-derivation of the stack.
struct Shell: View {
    @Environment(Fleet.self) private var fleet
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settings = false

    /// 1 normally, 0 under Reduce Motion. It multiplies every positional term,
    /// so staging survives as pure opacity rather than disappearing.
    private var mo: Double { reduceMotion ? 0 : 1 }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            FleetLayer(fleet: fleet, onSettings: { settings = true })
                .zIndex(Z.fleet)
        }
        .coordinateSpace(name: Space.shell)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $settings) { SettingsSheet() }
        .task { fleet.apply(roster: Fixture.roster) }
    }
}
