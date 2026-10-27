// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AnchorUtilities",
    platforms: [.macOS("26.0")],
    products: [.library(name: "AnchorUtilities", targets: ["AnchorUtilities"])],
    targets: [
        .systemLibrary(name: "HIDEventSystem"),
        .systemLibrary(name: "VMStatisticsCompat"),
        .target(
            name: "AnchorUtilities",
            dependencies: ["HIDEventSystem", "VMStatisticsCompat"],
            resources: [.copy("Resources/now-playing.pl"), .copy("Resources/agent-prices.json")],
            swiftSettings: [.define("ANCHOR_UTILITIES_DEVELOPMENT", .when(configuration: .debug))]
        ),
        .testTarget(name: "AnchorUtilitiesTests", dependencies: ["AnchorUtilities"])
    ]
)
