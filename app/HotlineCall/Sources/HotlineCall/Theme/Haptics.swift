import CoreHaptics
import SwiftUI
import UIKit

/// A rate limit around `.sensoryFeedback`.
///
/// APP-PLAN 4.8: `.sensoryFeedback` fires on **every** trigger change, and a
/// detent crossed during a fast scrub would fire twenty times in a second. The
/// budget is 90 ms, and it wraps the place the trigger is bumped rather than
/// the place it is consumed -- so a suppressed pulse costs nothing at all
/// rather than being scheduled and dropped.
///
/// A value type held as `@State` per surface, not a singleton: only one surface
/// is under a finger at a time, and a shared object would be a global to keep
/// in step for no gain.
struct HapticBudget {
    private var lastAt: Date = .distantPast
    /// Bump this into a `.sensoryFeedback(_:trigger:)`.
    private(set) var pulse = 0

    /// Returns whether the pulse was actually spent, for call sites that want
    /// to know. Most do not.
    @discardableResult
    mutating func fire(_ now: Date = .now) -> Bool {
        guard now.timeIntervalSince(lastAt) >= 0.09 else { return false }
        lastAt = now
        pulse &+= 1
        return true
    }
}

/// The slam card's two multi-pulse patterns, and the only Core Haptics in the
/// app (APP-PLAN 4.8).
///
/// `UIImpactFeedbackGenerator` produces single canned pulses and cannot express
/// either of these, which is the whole reason a second mechanism exists.
/// Everything else in the app is `.sensoryFeedback` and has no engine lifetime
/// to manage.
///
/// **No sound.** `playsHapticsOnly = true` is not a preference: it is what makes
/// it impossible for this engine to produce one by accident. `AVFoundation` is
/// not imported anywhere in this app, there is no `.audioFeedback` and no system
/// sound id, and the linker is the check -- see `docs/BUILDING.md`.
///
/// Main-actor `final class` holding one `CHHapticEngine`, kept alive for the
/// app's lifetime. The engine is not `Sendable` and its reset and stopped
/// handlers arrive on an arbitrary queue; **those two closures are the only
/// place in the app that uses `MainActor.assumeIsolated`**, and they assert
/// rather than hop, so a wrong-thread delivery traps loudly instead of racing
/// silently.
@MainActor
final class Haptics {
    static let shared = Haptics()

    /// (relativeTime, intensity, sharpness). Straight out of APP-PLAN 4.8.
    typealias Pattern = [(Double, Float, Float)]

    /// The answer card: `[10, 40, 18]` -- two transients, 50 ms apart.
    static let answer: Pattern = [(0.000, 0.55, 0.5), (0.050, 0.85, 0.7)]
    /// The kill card: `[18, 60, 18, 60, 26]` -- five stages, heavier than the
    /// answer's single pattern, so a destructive act is separable from a
    /// routine one purely through touch.
    static let kill: Pattern = [(0.000, 0.75, 0.6), (0.078, 0.75, 0.6), (0.156, 1.00, 0.8)]

    private var engine: CHHapticEngine?
    private var started = false

    /// Checked once. If the hardware cannot do this, both patterns degrade to a
    /// single heavy impact and nothing else changes.
    private lazy var supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private init() {}

    func play(_ pattern: Pattern) {
        guard supported, let engine = ensure() else {
            fallback()
            return
        }
        let events = pattern.map { at, intensity, sharpness in
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: at)
        }
        do {
            let built = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: built).start(atTime: CHHapticTimeImmediate)
        } catch {
            fallback()
        }
    }

    private func ensure() -> CHHapticEngine? {
        if let engine, started { return engine }
        do {
            let made = try engine ?? CHHapticEngine()
            made.playsHapticsOnly = true
            made.isAutoShutdownEnabled = true
            made.resetHandler = {
                // Arrives on an arbitrary queue. Asserting rather than hopping
                // means a wrong-thread delivery traps here instead of racing.
                MainActor.assumeIsolated { Haptics.shared.started = false }
            }
            made.stoppedHandler = { _ in
                MainActor.assumeIsolated { Haptics.shared.started = false }
            }
            try made.start()
            engine = made
            started = true
            return made
        } catch {
            return nil
        }
    }

    private func fallback() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
    }
}
