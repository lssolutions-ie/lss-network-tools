// swift-tools-version: 6.0
// LSS Network Tools — native macOS GUI for the lss-network-tools bash engine.
// Build with `make build` (see Makefile); never requires opening Xcode.
import PackageDescription

let package = Package(
    name: "LSSNetworkTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LSSNetworkTools", targets: ["LSSNetworkTools"]),
        .library(name: "LSSCore", targets: ["LSSCore"]),
    ],
    dependencies: [
        // MIT — embedded terminal (pty) used to run `sudo lss-network-tools`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // MIT — typed UserDefaults keys.
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.2.0"),
    ],
    targets: [
        // Foundation-only: models, decoding, CLI discovery/contract. Unit-tested, no AppKit.
        .target(
            name: "LSSCore",
            path: "Sources/LSSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LSSNetworkTools",
            dependencies: [
                "LSSCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Defaults", package: "Defaults"),
            ],
            path: "Sources/LSSNetworkTools",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LSSCoreTests",
            dependencies: ["LSSCore"],
            path: "Tests/LSSCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
