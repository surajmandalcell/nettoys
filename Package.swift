// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NetToys",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetToysCore", targets: ["NetToysCore"]),
        .library(name: "NetToysKit", targets: ["NetToysKit"]),
        .executable(name: "NetToys", targets: ["NetToysApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/surajmandalcell/oneplus-ui.git", exact: "1.3.37"),
    ],
    targets: [
        .target(name: "NetToysCore", resources: [.process("Resources")]),
        .target(name: "NetToysKit", dependencies: ["NetToysCore", .product(name: "OnePlusUI", package: "oneplus-ui")],
                resources: [.copy("Resources/NetToysGlyph.svg")]),
        .executableTarget(name: "NetToysApp", dependencies: ["NetToysCore", "NetToysKit", .product(name: "OnePlusUI", package: "oneplus-ui")]),
        .target(name: "NetToysLockFixture", path: "Tests/Fixtures/LockProcess"),
        .testTarget(name: "NetToysCoreTests", dependencies: ["NetToysCore", "NetToysLockFixture"]),
        .testTarget(name: "NetToysKitTests", dependencies: ["NetToysCore", "NetToysKit"]),
    ]
)
