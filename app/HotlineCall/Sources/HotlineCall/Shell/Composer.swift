import SwiftUI

/// The composer, and it is deliberately dumb.
///
/// Bogdan's own instruction, quoted in both prototypes' fixtures: *"keep the
/// composer dumb."* The draft is `@State` here and nowhere else -- it is not
/// store state, it does not survive a channel switch, and nothing else in the
/// app can read it.
///
/// **It has no reference to the feed.** Bug 1's cause was `follow()` being
/// called from `send()`, so a channel nobody typed into never streamed. There
/// is no code path from here to `Channel.run` to forget.
struct Composer: View {
    let answering: Bool
    let send: (String) -> Void

    @State private var draft = ""
    @State private var throwBy: CGSize = .zero
    @State private var throwing = false
    @FocusState private var typing: Bool

    /// APP-PLAN 4.7: release above -110 pt, or faster than -420 pt/s, commits.
    private static let commitDistance: Double = -110
    private static let commitVelocity: Double = -420

    private var ready: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField(answering ? "Answer" : "Say something",
                      text: $draft, axis: .vertical)
                .text(.body)
                .foregroundStyle(Theme.ink)
                .tint(Theme.sig)
                .lineLimit(1...5)
                .focused($typing)
                .submitLabel(.send)
                .onSubmit(commit)

            knob
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.surf)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.line, lineWidth: 1))
        )
        .padding(.horizontal, Theme.edge)
        .padding(.bottom, 12)
    }

    // MARK: - The knob, and the throw

    /// **Tapping send also works and does the same thing.** The gesture is the
    /// delight, not the only path -- which is also what keeps the control
    /// reachable to VoiceOver and to a shaky hand.
    private var knob: some View {
        ZStack {
            if throwing, ready { ghost }
            Circle()
                .fill(ready ? Theme.ink : Theme.ink5)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ready ? Theme.bg : Theme.ink4)
                )
                .scaleEffect(throwing ? 0.9 : 1)
                .animation(.settle, value: throwing)
        }
        .contentShape(Circle())
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(answering ? "Send answer" : "Send")
        .accessibilityAction { commit() }
        // One recognizer for both outcomes. A `Button` here would take the
        // touch before the drag could start, so the throw would never arm.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard ready else { return }
                    if !throwing, abs(value.translation.height) < 4,
                       abs(value.translation.width) < 4 { return }
                    throwing = true
                    throwBy = value.translation
                }
                .onEnded { value in
                    defer { throwing = false; throwBy = .zero }
                    guard ready else { return }
                    guard throwing else { commit(); return }
                    if value.translation.height < Self.commitDistance
                        || value.velocity.height < Self.commitVelocity {
                        commit()
                    }
                }
        )
    }

    /// The bubble follows the finger at `x * 0.55`, rotates with the sideways
    /// travel, and grows with the height -- so the throw has weight before it
    /// has committed to anything.
    private var ghost: some View {
        Text(draft)
            .text(.body)
            .foregroundStyle(Theme.ink)
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: Theme.bubbleRadius).fill(Theme.surf2))
            .frame(maxWidth: 240)
            .fixedSize(horizontal: false, vertical: true)
            .rotationEffect(.degrees(clamp(throwBy.width * 0.05, -9, 9)))
            .scaleEffect(1 + clamp(-throwBy.height / 900, 0, 0.18))
            .offset(x: throwBy.width * 0.55, y: throwBy.height)
            .opacity(0.9)
            .allowsHitTesting(false)
    }

    private func commit() {
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        send(text)
    }
}
