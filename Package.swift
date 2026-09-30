// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "NetToys",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NetToysKit", targets: ["NetToysKit"]),
        .executable(name: "NetToys", targets: ["NetToysApp"]),
    ],
    targets: [
        .target(name: "NetToysKit"),
        .executableTarget(name: "NetToysApp", dependencies: ["NetToysKit"]),
    ]
)
