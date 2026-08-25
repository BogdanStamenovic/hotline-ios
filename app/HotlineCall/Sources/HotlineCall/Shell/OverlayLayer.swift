import SwiftUI

/// Chrome that belongs to no screen: the reachability banner and the coach
/// toast now; the flying title in step 3.
struct OverlayLayer: View {
    let reachable: Reachability
    let toast: Toast?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            VStack(spacing: 8) {
                if case .stale(let since, let why) = reachable {
                    StaleBanner(since: since, why: why)
                }
                Spacer(minLength: 0)
                if let toast {
                    ToastView(text: toast.text)
                        .id(toast.id)
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .padding(.horizontal, Theme.edge)
            .padding(.vertical, 10)
            .animation(.enter, value: reachable)
            .animation(.enter, value: toast)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Banners

/// The roster on screen is not the roster on archserver, and it says so with
/// the time it stopped being true rather than a spinner that implies progress.
private struct StaleBanner: View {
    let since: Date?
    let why: String

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(Theme.sig).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(since.map { "SHOWING \(ago($0).uppercased()) OLD DATA" }
                     ?? "CAN'T REACH ARCHSERVER")
                    .text(.label(9.5))
                    .foregroundStyle(Theme.sig)
                Text(why)
                    .text(.rowSubtitle)
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.cardRadius)
                .fill(Theme.surf)
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .stroke(Theme.sig20, lineWidth: 1))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .text(.rowSubtitle)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: Theme.cardRadius)
                    .fill(Theme.surf2)
                    .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
                        .stroke(Theme.line2, lineWidth: 1))
            )
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
