import AVFoundation
import CallKit
import Foundation
import OSLog

/// The thing that makes the phone actually ring.
///
/// **This is the whole point of the project**, so it is worth being precise
/// about what does and does not need Apple's money:
///
///   * **CallKit needs no entitlement.** `CXProvider.reportNewIncomingCall` is
///     ordinary API. That is why this exists at all on a free Apple ID.
///   * **PushKit does** -- `aps-environment` is not granted to free
///     provisioning, verified against Apple's own capabilities table. So this
///     app never instantiates a `PKPushRegistry`, and the iOS 13 rule that a
///     VoIP push must be answered with a call report never applies to it: that
///     rule binds apps that *accept* such a push.
///
/// The consequence, stated plainly because it is the honest limit of this
/// design: **something else has to still be running to call `report(...)`.**
/// A push wakes a dead process; this cannot. If the app has been force-quit, or
/// the phone has rebooted, nothing here runs and nothing rings. The server is
/// built to detect that and fall back rather than let a call vanish -- see
/// `ConfirmedRing` on the server side.
@Observable
final class CallCenter: NSObject {
    private(set) var phase: CallPhase = .idle
    private(set) var moments: [Moment] = []
    /// What Claude is running right now, for the in-call screen.
    private(set) var currentTool: String?

    private let provider: CXProvider
    private let controller = CXCallController()
    private let link: Link
    private let log = Logger(subsystem: "dev.stamenovic.hotlinecall", category: "call")
    private var callID: String?
    private var feed: Task<Void, Never>?

    init(link: Link) {
        self.link = link
        let config = CXProviderConfiguration()
        config.supportsVideo = false
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        // Show it as a generic call rather than a phone number: there is no
        // number, and a fake one in Recents would be worse than none.
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        self.provider = CXProvider(configuration: config)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Ring this phone, now. Called when the server says a session wants him.
    func report(callID: String, from who: String, reason: String) async {
        self.callID = callID
        let update = CXCallUpdate()
        update.localizedCallerName = who
        update.remoteHandle = CXHandle(type: .generic, value: who)
        update.hasVideo = false
        phase = .ringing(from: who, reason: reason)
        do {
            try await provider.reportNewIncomingCall(with: uuid(for: callID), update: update)
            log.notice("reported incoming call \(callID, privacy: .public)")
        } catch {
            // iOS refuses the report in Do Not Disturb, in a call, and when the
            // system decides otherwise. Not a crash -- the server has to be
            // told so it can fall back to the Discord page.
            log.error("iOS refused the call: \(error.localizedDescription, privacy: .public)")
            phase = .ended(reason: "iOS refused to ring")
        }
    }

    func hangUp() {
        guard let callID else { return }
        let end = CXEndCallAction(call: uuid(for: callID))
        controller.request(CXTransaction(action: end)) { [log] error in
            if let error { log.error("end call: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func uuid(for callID: String) -> UUID {
        // Derive a stable UUID from the server's call id so that answering and
        // ending refer to the same call across a relaunch.
        var bytes = Array(callID.utf8.prefix(16))
        bytes.append(contentsOf: Array(repeating: 0, count: max(0, 16 - bytes.count)))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private func startFeed() {
        guard let callID else { return }
        feed?.cancel()
        feed = Task { [link] in
            for await moment in link.moments(callID: callID) {
                apply(moment)
            }
        }
    }

    private func apply(_ moment: Moment) {
        moments.append(moment)
        switch moment.kind {
        case .tool: currentTool = moment.tool ?? moment.text
        case .said, .heard: currentTool = nil
        case .state where moment.text == "ended": phase = .ended(reason: "hung up")
        default: break
        }
    }

    private func finish(_ reason: String) {
        feed?.cancel()
        feed = nil
        callID = nil
        currentTool = nil
        phase = .ended(reason: reason)
    }
}

// CallKit calls these on its own queue, so they are nonisolated and hop
// deliberately. `assumeIsolated` is wrong here -- these genuinely arrive off
// the main actor, so it would trap rather than help.
extension CallCenter: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in self.finish("call system reset") }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            self.phase = .connected(since: .now)
            self.startFeed()
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            if let id = self.callID { await self.link.hangUp(callID: id) }
            self.finish("ended")
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // Audio starts here, not on answer: before this point the system has
        // not handed us the route.
    }
}
