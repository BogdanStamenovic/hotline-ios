import CoreText
import Foundation
import OSLog
import SwiftUI

/// Geist, bundled as a package resource and registered at launch.
///
/// **Why bundle at all** (APP-PLAN 12.4): Kinetic Prime -- the concept he
/// approved -- is set in Geist, and that is the face he judged. SF differs
/// visibly in width and character, and Prime's density and its whole type ramp
/// were tuned against Geist. Shipping SF would ship something he did not
/// approve. A bundled font file is a resource, not a dependency.
///
/// **Why static faces rather than the variable file.** APP-PLAN 4.1 names the
/// variable `Geist[wght].ttf`. It is not used, and the reason is that this box
/// cannot run the app: selecting a weight on a registered variable font goes
/// through Core Text's descriptor matching, and if it silently resolves to the
/// wrong instance the failure looks exactly like the fallback-face failure
/// 12.4 warns about -- a slightly-wrong page nobody notices. Naming the face
/// outright (`Geist-SemiBold`) removes the matching step entirely: the weight
/// is a filename, not a negotiation. Four files, ~380 KB, deterministic.
///
/// Files are the upstream ones from `vercel/geist-font`, with `OFL.txt`
/// alongside them as the licence requires.
nonisolated enum Fonts {
    /// SwiftPM's own `Bundle.module` accessor is deliberately **not** used.
    ///
    /// Two reasons, and the first is the serious one: the generated accessor
    /// ends in `fatalError("could not load resource bundle")`, so a packaging
    /// failure would take the app down at launch instead of falling back to SF.
    /// A missing typeface must degrade, not crash. (The second is that the
    /// accessor is a `static let` in this module and therefore main-actor
    /// isolated, which would drag `Theme.font` onto the main actor with it.)
    ///
    /// The name is SwiftPM's `<Package>_<Target>.bundle` convention, checked
    /// against the built archive rather than assumed:
    /// `Payload/HotlineCall.app/HotlineCall_HotlineCall.bundle/Geist-*.ttf`.
    private static let resources: Bundle = {
        let url = Bundle.main.bundleURL.appendingPathComponent("HotlineCall_HotlineCall.bundle")
        // `Bundle.main` as the fallback covers a packager that flattens
        // resources into the app bundle instead of nesting them.
        return Bundle(url: url) ?? Bundle.main
    }()
    /// The PostScript names, read out of each file's `name` table rather than
    /// guessed. `Theme.font` asks for one of these by name.
    static let faces = ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold"]

    private static let log = Logger(subsystem: "dev.stamenovic.hotline", category: "fonts")

    /// Registered once, lazily and atomically, the way every Swift global is.
    /// `HotlineApp.init` touches it so the work happens at launch rather than
    /// inside the first `body` that needs a glyph.
    static let registered: Bool = register()

    /// The face for a weight, or `nil` when the bundle did not come through --
    /// in which case every call site falls back to SF with the tracking table
    /// applied unchanged, which is APP-PLAN 4.1's named fallback and holds the
    /// density.
    static func face(for weight: Font.Weight) -> String? {
        guard Theme.family != nil, registered else { return nil }
        switch weight {
        case .bold, .heavy, .black: return "Geist-Bold"
        case .semibold: return "Geist-SemiBold"
        case .medium: return "Geist-Medium"
        default: return "Geist-Regular"
        }
    }

    private static func register() -> Bool {
        var everything = true
        for face in faces {
            guard let url = resources.url(forResource: face, withExtension: "ttf") else {
                log.error("\(face, privacy: .public) is not in the bundle")
                everything = false
                continue
            }
            var failure: Unmanaged<CFError>?
            // `.process` scope: this app's fonts, not the device's. Nothing is
            // installed system-wide and nothing survives the process.
            if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &failure) {
                let error = failure?.takeRetainedValue()
                let code = CFErrorGetCode(error)
                // Already registered is not a failure -- it is what a second
                // call looks like, and a second call is cheap to allow.
                if code != CTFontManagerError.alreadyRegistered.rawValue {
                    log.error("\(face, privacy: .public): CTFontManager code \(code)")
                    everything = false
                }
            }
        }
        return everything
    }
}
