// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RamblrKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "RamblrKit", targets: ["RamblrKit"]),
    ],
    targets: [
        .target(name: "RamblrKit"),
        .testTarget(name: "RamblrKitTests", dependencies: ["RamblrKit"]),
    ]
)
