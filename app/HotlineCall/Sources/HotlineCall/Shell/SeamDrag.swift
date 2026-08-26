import SwiftUI

/// The one recognizer every 0...1 seam in this app is dragged by.
///
/// It exists because four hand-written copies of the same gesture had the same
/// two defects, and both of them are the kind that only show up in the hand.
///
/// **1. It snapshots where the seam started.** The copies wrote
/// `progress ± translation/height`, reading the *live* `progress` — which the
/// previous callback had already moved. SwiftUI hands the updated view's
/// closures to the running gesture, so the delta compounded: on an 850 pt sheet
/// dragged 200 pt in fifteen samples the term is `1 − d·n(n+1)/2` rather than
/// `1 − d·n`, and the panel is fully closed by the eleventh sample of a drag the
/// finger is still in the middle of. `BackStrip` already did this correctly with
/// its own `startProgress`; this is that, once, for everybody.
///
/// **2. It reports its own cancellation.** A SwiftUI drag that is cancelled
/// never calls `onEnded`, so nothing runs the release and the seam is left
/// wherever the finger was — the one resting state `seamTarget` says cannot
/// exist. `@GestureState` is the only thing SwiftUI *guarantees* to reset on a
/// cancel, so the recovery hangs off that: if the reset arrives while a drag is
/// still open, the seam is committed on position alone.
///
/// The cancellation this was written for was self-inflicted — a layer whose
/// `allowsHitTesting` was a function of the very scalar the drag was writing,
/// so crossing 0.5 disarmed the recognizer mid-gesture. That is fixed at the
/// source (the gates now stay put for the duration of a drag). This is the net
/// under it, for the cancellations that are not ours: a system alert, a call
/// banner, the atomic lock landing mid-drag.
struct SeamDrag: ViewModifier {
    /// The seam's current value, read once when the drag opens.
    let progress: Double
    let minimumDistance: Double
    /// Where the finger has travelled, in seam units. Sign included.
    let delta: (CGSize) -> Double
    /// Finger velocity, in seam units per second. Sign included.
    let rate: (CGSize) -> Double
    /// Which touches this seam answers for. The map's blind owns only its
    /// grabber; everything else owns its whole panel.
    let accepts: (CGPoint) -> Bool
    let phase: (SheetPhase) -> Void

    @GestureState private var live = false
    /// Non-nil exactly while a drag this seam accepted is open. It is also the
    /// idempotence token: a release clears it, so a cancellation that arrives
    /// afterwards is a no-op whatever order SwiftUI delivers the two in.
    @State private var start: Double?

    init(progress: Double,
         minimumDistance: Double = 6,
         accepts: @escaping (CGPoint) -> Bool = { _ in true },
         delta: @escaping (CGSize) -> Double,
         rate: @escaping (CGSize) -> Double,
         phase: @escaping (SheetPhase) -> Void) {
        self.progress = progress
        self.minimumDistance = minimumDistance
        self.accepts = accepts
        self.delta = delta
        self.rate = rate
        self.phase = phase
    }

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: minimumDistance)
                    .updating($live) { _, state, _ in state = true }
                    .onChanged { value in
                        guard accepts(value.startLocation) else { return }
                        let from = start ?? progress
                        if start == nil { start = from }
                        phase(.move(clamp(from + delta(value.translation), 0, 1)))
                    }
                    .onEnded { value in
                        guard start != nil else { return }
                        start = nil
                        phase(.release(rate(value.velocity)))
                    }
            )
            .onChange(of: live) { _, open in
                guard !open, start != nil else { return }
                start = nil
                // No velocity: a cancelled gesture has no release to read one
                // from, and inventing one would decide the commit for him.
                phase(.release(0))
            }
    }
}

extension View {
    func seamDrag(progress: Double,
                  minimumDistance: Double = 6,
                  accepts: @escaping (CGPoint) -> Bool = { _ in true },
                  delta: @escaping (CGSize) -> Double,
                  rate: @escaping (CGSize) -> Double,
                  phase: @escaping (SheetPhase) -> Void) -> some View {
        modifier(SeamDrag(progress: progress, minimumDistance: minimumDistance,
                          accepts: accepts, delta: delta, rate: rate, phase: phase))
    }
}
