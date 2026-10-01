// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NetToys",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetToysCore", targets: ["NetToysCore"]),
        .library(name: "NetToysKit", targets: ["NetToysKit"]),
        .executable(name: "NetToys", targets: ["NetToysApp"]),
        .executable(name: "NetToysHelper", targets: ["NetToysHelper"]),
    ],
    dependencies: [
        .package(path: "../oneplus-ui"),
    ],
    targets: [
        .target(name: "NetToysCore", resources: [.process("Resources")]),
        .target(name: "NetToysKit", dependencies: ["NetToysCore", .product(name: "OnePlusUI", package: "oneplus-ui")]),
        .executableTarget(name: "NetToysApp", dependencies: ["NetToysCore", "NetToysKit", .product(name: "OnePlusUI", package: "oneplus-ui")]),
        .executableTarget(name: "NetToysHelper", dependencies: ["NetToysCore"]),
        .target(name: "NetToysLockFixture", path: "Tests/Fixtures/LockProcess"),
        .testTarget(name: "NetToysCoreTests", dependencies: ["NetToysCore", "NetToysLockFixture"]),
        .testTarget(name: "NetToysKitTests", dependencies: ["NetToysCore", "NetToysKit"]),
    ]
)
