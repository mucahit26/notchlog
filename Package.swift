// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchLog",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "notchlog", targets: ["NotchLog"]),
    ],
    // Intentionally empty. A zero-dependency package has no supply chain to audit,
    // which is part of this project's security posture. CI enforces that it stays empty.
    dependencies: [],
    // NOTE: there is no test target on purpose. Neither XCTest nor swift-testing ships
    // with the Command Line Tools, so `swift test` cannot run on a machine without Xcode —
    // and building without Xcode is the whole point of this package. The test suite is
    // instead an ordinary subcommand, `notchlog selftest`, which runs everywhere.
    targets: [
        .target(name: "NotchLogKit"),
        .executableTarget(name: "NotchLog", dependencies: ["NotchLogKit"]),
    ]
)
