// swift-tools-version: 5.10
import PackageDescription

let strictSwiftSettings: [SwiftSetting] = [
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

let package = Package(
    name: "PeekPane",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PeekPane", targets: ["PeekPane"]),
        .executable(name: "PeekPaneNativeHost", targets: ["PeekPaneNativeHost"]),
        .library(name: "PeekPaneBridgeWire", targets: ["PeekPaneBridgeWire"])
    ],
    targets: [
        .target(
            name: "PeekPaneBridgeWire",
            path: "Sources/PeekPaneBridgeWire",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "PeekPane",
            dependencies: ["PeekPaneBridgeWire"],
            path: "Sources/PeekPane",
            swiftSettings: strictSwiftSettings
        ),
        .executableTarget(
            name: "PeekPaneNativeHost",
            dependencies: ["PeekPaneBridgeWire"],
            path: "Sources/PeekPaneNativeHost",
            swiftSettings: strictSwiftSettings
        ),
        .testTarget(
            name: "PeekPaneBridgeWireTests",
            dependencies: ["PeekPaneBridgeWire"],
            path: "Tests/PeekPaneBridgeWireTests",
            swiftSettings: strictSwiftSettings
        )
    ]
)
