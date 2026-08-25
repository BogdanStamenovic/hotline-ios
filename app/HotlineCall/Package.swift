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
                // Main-actor-by-default. Every type in this module is
                // UI-facing state, so annotating each one would be noise. The
                // one thing that genuinely runs off the main actor -- Link's
                // URLSession work -- says `nonisolated` at its own definition,
                // which is where a reader looking for it would go.
                .defaultIsolation(MainActor.self),
            ]
        ),
    ]
)
