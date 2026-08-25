import SwiftUI

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

/// Core Haptics is deliberately absent from this build.
///
/// It is needed for exactly two things -- the slam card's multi-pulse patterns
/// (APP-PLAN 4.8), which `UIImpactFeedbackGenerator` cannot express -- and
/// those are step 9. Everything up to here is single-pulse and declarative, so
/// there is no engine lifetime to manage and nothing that could make a sound.
///
/// **No sound anywhere.** `AVFoundation` is not imported by this app, there is
/// no `.audioFeedback` and no system sound id.
nonisolated enum Sound {}
