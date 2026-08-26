# Building the iOS app on Arch Linux

No Mac. Clean build is about 7 seconds.

    source /mnt/iosbuild/env62.sh
    cd app/HotlineCall
    /mnt/iosbuild/toolchain/xtool.AppImage dev build --ipa
    # -> app/HotlineCall/xtool/HotlineCall.ipa

Result, verified by inspecting the file rather than trusting the exit code:

    Mach-O 64-bit arm64 executable  (magic 0xfeedfacf)
    linked: SwiftUI, UIKit, Foundation, CoreFoundation, CoreGraphics,
            CoreText, CoreHaptics
    bundle: dev.stamenovic.hotlinecall, MinimumOSVersion 18.0, iPhoneOS
    9.7 MB ipa (unoptimised debug binary, plus a 510 KB font bundle)

`CoreHaptics` arrived with step 9 and is the only framework the slam card
needed. **`AVFoundation` and `AudioToolbox` are absent, and that is the check
for the no-sound rule** -- not a code review, the linker:

    strings -a Payload/HotlineCall.app/HotlineCall | grep -cE 'AVFoundation|AVAudio|AudioToolbox'
    # -> 0

The haptic engine additionally runs with `playsHapticsOnly = true`, so it
cannot produce one even by accident.

`MinimumOSVersion` is 18.0 since the redesign: his phone is on 18.7.8,
there is no second device to support, and `onGeometryChange` -- iOS 18 --
is on the critical path for the scene change's hero flight.

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

## Three gotchas worth keeping

- **`swift sdk install`, not `xtool sdk install`.** On Linux the latter wants an
  `Xcode.xip`. The artifactbundle is a standard SwiftPM Swift SDK bundle.
- **`swiftc -parse` proves nothing here.** It is syntax-only and never reads
  `Package.swift`. It called all six sources clean for hours while the manifest
  could not compile at all (`defaultIsolation` needs tools-version 6.2, and it
  said 6.0).

- **Adding or deleting a source file does not invalidate the build plan, and
  the build says `Build complete!` anyway.** `xtool dev build` copies the
  sources into `xtool/.xtool-tmp` and drives SwiftPM against that copy; when
  the set of files changes, the cached plan is reused and *none of the new code
  is compiled*. It is a green check that measured nothing -- the exact failure
  this project keeps running into. After adding, moving or removing a file:

        rm -rf .build xtool/.xtool-tmp

  Editing an existing file is fine: incremental works and is about a second.

## Verifying without a phone -- `app/wiretest/run.sh`

There is no Mac, no simulator and no way to execute SwiftUI here. But
`Wire/Wire.swift`, `Wire/Rules.swift` and `Store/SampleRing.swift` import only
Foundation, so they compile and **run** natively on Linux with the same
toolchain. That is the only executable verification this box has, so as much
decision-making as possible is deliberately kept in those three files:

    app/wiretest/run.sh                  # against the checked-in fixtures
    app/wiretest/run.sh 100.72.2.62      # refresh the fixtures from a live daemon first

It compiles `Wire/Wire.swift`, `Wire/Rules.swift`, `Store/SampleRing.swift`,
`Store/Route.swift` and `Theme/Scalars.swift`. **A file only joins that list by
importing Foundation alone**, which is why as much decision-making as possible
is deliberately pushed into those five.

194 checks as of step 10, in five parts:

- **The bytes the live daemon really sends today** -- old code, no `state`, no
  `vitals`, no `controls`, no `roster-events`. This is what proves the
  graceful-degradation claims rather than asserting them: an absent `Vitals`
  renders no cell, an absent capability list renders no controls, an absent
  timestamp renders no relative time.
- **The full contract the server is landing now** -- `vitals`,
  `contextAvailable`, `declaredAt`, `duration_ms`, `client_token`,
  `historyGeneration`, `controls` including a disabled one and an `id` this
  build cannot dispatch. Written from `SERVER-PLAN.md` §6 and §9 rather than
  from a running server, so the app is tested against the contract before the
  contract arrives.

- **A history page captured from the live daemon today** (`live-history.json`),
  which is what found the biggest plan defect: `/agents/history` sends **no
  `phases` key at all**, so the map's route has to be reconstructed from the
  event stream. The assertions are structural rather than hardcoded counts, so
  refreshing the fixture does not silently turn them green.
- **Today's roster and health** (`today-agents.json`, `today-health.json`),
  which is where the full contract is checked against a server that now
  actually implements it rather than against a written-down promise.

It also executes the rules that are easiest to get quietly wrong and impossible
to see in a build log: `reconciled(_:in:)`, which is the whole of bug 3's fix;
every readout's formatting -- including that a compaction with no numbers
renders *no* numbers rather than "in 0s"; `route(from:)`'s phase nesting, which
must place every tool row exactly once and never invent a title; `Playhead`'s
`Driver` arbitration, where a missing refusal is an oscillating map; the purge
dry-run reconciliation, where a missing comparison is a deletion he consented
to different numbers for; and the auto-open rule's three conditions.

Since step 10 the motion scalars live in `Theme/Scalars.swift` for the same
reason -- Foundation only, so `rubber`/`unrubber` round-trip, `win`'s
smoothstep and the map's focus band are executed rather than eyeballed.

**`run.sh` deletes the built binary before compiling.** A stale binary from a
previous run, passing its own older assertions, is the same
green-check-that-measured-nothing as the cached build plan below. It has
already happened once here.

## Resources -- the ipa carries a bundle now

Geist is bundled (`APP-PLAN.md` §12.4), so `Package.swift` declares
`resources: [.process("Resources")]` and the archive gains a nested bundle:

    Payload/HotlineCall.app/HotlineCall_HotlineCall.bundle/Geist-{Regular,Medium,SemiBold,Bold}.ttf
    Payload/HotlineCall.app/HotlineCall_HotlineCall.bundle/OFL.txt

**Verify it by listing the archive, not by a clean build** -- a build that
silently drops a resource looks identical to one that carries it:

    unzip -l xtool/HotlineCall.ipa

Two things worth knowing about that path. SwiftPM's generated `Bundle.module`
accessor is deliberately **not** used: it ends in
`fatalError("could not load resource bundle")`, so a packaging failure would
take the app down at launch instead of falling back to SF. `Theme/Fonts.swift`
resolves the bundle by name and degrades. And the faces are named outright
(`Geist-SemiBold`) rather than selected by weight trait, because weight
resolution cannot be tested here and picking the wrong instance is a silent
failure.

`Theme.family = nil` is still the one-line fallback to SF.

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
