// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "PeekPane",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PeekPane", targets: ["PeekPane"])
    ],
    targets: [
        .executableTarget(
            name: "PeekPane",
            path: "Sources/PeekPane",
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("ConciseMagicFile"),
                .enableUpcomingFeature("ForwardTrailingClosures"),
                .enableUpcomingFeature("ImplicitOpenExistentials"),
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .enableUpcomingFeature("DisableOutwardActorInference"),
                .enableUpcomingFeature("GlobalConcurrency"),
                .enableUpcomingFeature("IsolatedDefaultValues"),
                .enableExperimentalFeature("StrictConcurrency")
            ]
        )
    ]
)
