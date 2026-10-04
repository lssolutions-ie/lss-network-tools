// swift-tools-version: 6.0
// LSS Network Tools — native macOS GUI for the lss-network-tools bash engine.
// Build with `make build` (see Makefile); never requires opening Xcode.
import PackageDescription

let package = Package(
    name: "LSSNetworkTools",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "LSSNetworkTools", targets: ["LSSNetworkTools"]),
        .executable(name: "LSSHelper", targets: ["LSSHelper"]),
        .library(name: "LSSCore", targets: ["LSSCore"]),
    ],
    dependencies: [
        // MIT — embedded terminal (pty) used to run `sudo lss-network-tools`.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.20.0"),
        // MIT — typed UserDefaults keys.
        .package(url: "https://github.com/sindresorhus/Defaults.git", from: "8.2.0"),
        // MIT — in-app updates from the committed appcast (macos/appcast.xml).
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
    ],
    targets: [
        // Foundation-only: models, decoding, CLI discovery/contract. Unit-tested, no AppKit.
        .target(
            name: "LSSCore",
            path: "Sources/LSSCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The XPC protocol and request DTOs shared by the app and the privileged helper.
        .target(
            name: "LSSXPC",
            path: "Sources/LSSXPC",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // The SMAppService LaunchDaemon (Contents/MacOS/LSSHelper). Foundation only.
        .executableTarget(
            name: "LSSHelper",
            dependencies: ["LSSXPC", "LSSCore"],
            path: "Sources/LSSHelper",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "LSSNetworkTools",
            dependencies: [
                "LSSCore",
                "LSSXPC",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/LSSNetworkTools",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "LSSCoreTests",
            dependencies: ["LSSCore", "LSSXPC"],
            path: "Tests/LSSCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
