import SwiftUI

/// APP-PLAN 4.6's `blurSwap`, as one reusable component.
///
/// Applied to every text that changes meaning under his eyes -- row subtitles,
/// the channel's state line, the fleet counts. Two states must never sit
/// legibly on top of each other, and a hard cut looks broken.
///
/// Out over 190 ms (opacity to 0, blur 4 pt, offset -5), the string is swapped
/// at the bottom of that, then in from +5 over 220 ms.
///
/// **Never animate a no-op.** The guard on the string actually differing is not
/// an optimisation: a roster tick that re-sends the same subtitle would
/// otherwise blink the row every few seconds for no reason at all.
///
/// For pure digits use `.contentTransition(.numericText())` instead, which does
/// the same job per glyph.
struct BlurSwap<Content: View>: View {
    let text: String
    @ViewBuilder let content: (String) -> Content

    @State private var shown: String = ""
    @State private var phase: Double = 1      // 1 settled, 0 mid-swap
    @State private var rising = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content(shown)
            .modifier(Swap(phase: phase, rising: rising))
            .onAppear { shown = text }
            .onChange(of: text) { _, next in swap(to: next) }
            // The swap is decoration over a value VoiceOver should hear once.
            .accessibilityLabel(text)
    }

    private func swap(to next: String) {
        guard next != shown else { return }
        guard !reduceMotion else { shown = next; return }
        rising = false
        withAnimation(.easeIn(duration: 0.19)) { phase = 0 }
        Task {
            try? await Task.sleep(for: .milliseconds(190))
            shown = next
            rising = true
            withAnimation(.easeOut(duration: 0.22)) { phase = 1 }
        }
    }
}

/// The blur, opacity and offset as one `Animatable` modifier.
///
/// Writing `.blur(radius: (1 - phase) * 4)` directly would read the *model*
/// value, which `withAnimation` sets to its target immediately -- so the text
/// would jump to blurred and back rather than travelling. Owning `phase` as
/// `animatableData` is what makes SwiftUI interpolate it and re-evaluate here.
///
/// **Blur is quantised to whole points.** A radius that changes every frame
/// forces a re-rasterisation every frame; quantised, the layer re-rasterises
/// about four times across the swap. It matters on a phone and it is free.
private nonisolated struct Swap: ViewModifier, Animatable {
    var phase: Double
    let rising: Bool

    var animatableData: Double {
        get { phase }
        set { phase = newValue }
    }

    @MainActor func body(content: Content) -> some View {
        content
            .blur(radius: ((1 - phase) * 4).rounded())
            .opacity(phase)
            .offset(y: (1 - phase) * (rising ? 5 : -5))
    }
}
