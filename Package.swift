// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "C64Emu",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "C64Core", targets: ["C64Core"]),
        .executable(name: "C64Emu", targets: ["C64App"]),
    ],
    targets: [
        .target(name: "C64Core"),
        .executableTarget(
            name: "C64App",
            dependencies: ["C64Core"]
        ),
        .testTarget(
            name: "C64CoreTests",
            dependencies: ["C64Core"]
        ),
    ]
)
