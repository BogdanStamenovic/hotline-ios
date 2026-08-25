// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HotlineCall",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "HotlineCall", targets: ["HotlineCall"]),
    ],
    targets: [
        .target(
            name: "HotlineCall",
            swiftSettings: [
                // Main-actor-by-default. This is an app module whose state is
                // all UI-facing, so the isolation that matters is the main
                // actor and annotating each type would be noise. It also means
                // the CallKit delegate callbacks -- which arrive nonisolated --
                // have to say so explicitly, which is the correct place for the
                // reader's attention.
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
