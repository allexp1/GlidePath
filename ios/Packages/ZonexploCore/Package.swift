// swift-tools-version: 6.0
import PackageDescription

// ZonexploCore is deliberately UI-free and dependency-free: it is pure value
// types and pure functions over them. That is what lets the whole coaching
// engine be tested with `swift test` on any machine, with no simulator, no
// Xcode project and no network.
let package = Package(
    name: "ZonexploCore",
    platforms: [
        .iOS("26.0"),
        .macOS("14.0")
    ],
    products: [
        .library(name: "ZonexploCore", targets: ["ZonexploCore"])
    ],
    targets: [
        .target(
            name: "ZonexploCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ZonexploCoreTests",
            dependencies: ["ZonexploCore"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
