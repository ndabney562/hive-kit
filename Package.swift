// swift-tools-version: 6.0
import PackageDescription

// The Hive apps' shared logic (Noah, 2026-11-07: one Hive framework): HTTP transport, the read-only GitHub client and
// its device-flow sign-in. Foundation only, so `swift test` runs on a Mac and on Linux. The look lives in hive-design.
let package = Package(
    name: "HiveKit",
    platforms: [.iOS("27.0"), .macOS("27.0")],
    products: [
        .library(name: "HiveKit", targets: ["HiveKit"]),
    ],
    targets: [
        .target(name: "HiveKit"),
        .testTarget(name: "HiveKitTests", dependencies: ["HiveKit"]),
    ]
)
