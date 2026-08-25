import Foundation

/// Where archserver is, as a setting rather than a constant.
///
/// It was hardcoded to the tailnet address, which was wrong for two reasons.
/// The small one: it cannot be built in a public repository without publishing
/// his addressing. The real one: an address baked into a binary he re-signs
/// every week is an address he cannot change without a rebuild — and he has
/// several ways to reach that machine (tailnet, LAN, hostname) that are each
/// right at different times.
///
/// Stored in `UserDefaults`, which survives the weekly re-sign because the app's
/// bundle id does not change.
@Observable
final class Server {
    private static let key = "hotline.server"

    /// Empty until he sets it. The app asks on first run rather than guessing,
    /// because a wrong default fails as a timeout, and a timeout looks exactly
    /// like the server being down.
    var address: String {
        didSet { UserDefaults.standard.set(address, forKey: Self.key) }
    }

    init() {
        address = UserDefaults.standard.string(forKey: Self.key) ?? ""
    }

    var isConfigured: Bool { url != nil }

    /// Tolerates being given a bare host or `host:port`, because that is what
    /// someone types. A scheme is added and 8789 assumed.
    var url: URL? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var parts = URLComponents(string: withScheme), parts.host != nil else { return nil }
        if parts.port == nil { parts.port = 8789 }
        return parts.url
    }
}
