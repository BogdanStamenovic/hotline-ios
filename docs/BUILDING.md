# Building the iOS app on Arch Linux

No Mac. Clean build is about 7 seconds.

    source /mnt/iosbuild/env62.sh
    cd app/HotlineCall
    /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa
    # -> app/HotlineCall/xtool/HotlineCall.ipa

Result, verified by inspecting the file rather than trusting the exit code:

    Mach-O 64-bit arm64 executable  (magic 0xfeedfacf)
    linked: SwiftUI, UIKit, Foundation, CoreFoundation
    bundle: dev.stamenovic.hotlinecall, MinimumOSVersion 17.0, iPhoneOS
    1.4 MB ipa / 1,369,384-byte binary

## The three pieces

| Piece | Where | Why this one |
|---|---|---|
| Swift **6.2.3** for Ubuntu 24.04 | `/mnt/iosbuild/toolchain/swift-6.2.3-RELEASE-ubuntu24.04` | must match the SDK |
| Darwin SDK (Xcode 26.2) | `~/.swiftpm/swift-sdks/darwin.artifactbundle` | built on a free macOS runner |
| `xtool` 1.17.0 AppImage | `/mnt/iosbuild/toolchain/xtool.AppImage` | drives SwiftPM and packages the ipa |

## The version rule, which is the whole trick

**The Linux toolchain must match the Xcode the SDK came from. Newer is
rejected.** Xcode 26.2 ships Apple Swift 6.2 (`swiftlang-6.2.3.3.2`), so Swift
6.2.3 for Linux. With Swift 6.3.3 the build fails like this:

    failed to build module 'SwiftUI'; this SDK is not supported by the compiler
    (the SDK is built with 'Apple Swift version 6.2 ...', while this compiler is
    'Swift version 6.3.3'). Please select a toolchain which matches the SDK.

...plus 153 errors inside `arm_neon.h`. Those look like a separate, much nastier
problem — Apple's clang-1700 headers meeting open-source clang — but they are
the same mismatch one layer down and they all vanish with the right toolchain.
**Do not go debugging the NEON errors.** 6.3.3 is kept at
`/mnt/iosbuild/env.sh` only for diffing.

## Two gotchas worth keeping

- **`swift sdk install`, not `xtool sdk install`.** On Linux the latter wants an
  `Xcode.xip`. The artifactbundle is a standard SwiftPM Swift SDK bundle.
- **`swiftc -parse` proves nothing here.** It is syntax-only and never reads
  `Package.swift`. It called all six sources clean for hours while the manifest
  could not compile at all (`defaultIsolation` needs tools-version 6.2, and it
  said 6.0).

## Isolation, since the module is main-actor-by-default

`Package.swift` sets `.defaultIsolation(MainActor.self)`. Consequence: the five
wire types in `Model.swift` are marked `nonisolated`, because `Link` decodes
them off the main actor and a main-actor-isolated `Decodable` conformance
cannot be used from there. `Delivery` is deliberately left isolated — it is view
state.

## What this does not give you

The ipa is **unsigned**: no `LC_CODE_SIGNATURE`, no `embedded.mobileprovision`.
It cannot be installed as-is. See `docs/SIDELOADING.md` — signing needs his
Apple ID and the phone needs pairing by cable once, and neither is a tooling
gap that can be engineered away.
