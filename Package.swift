// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "C64Emu",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "C64Core", targets: ["C64Core"]),
        .executable(name: "C64Emu", targets: ["C64App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/AgentiLoop/AutoUpdateKit.git", from: "1.0.2"),
    ],
    targets: [
        // The chips touch each other's state every emulated cycle; runtime exclusivity checks
        // (swift_beginAccess) cost about as much as the emulation itself, so they're off here.
        .target(name: "C64Core", swiftSettings: [.unsafeFlags(["-enforce-exclusivity=unchecked", "-Ounchecked"])]),
        .executableTarget(
            name: "C64App",
            dependencies: ["C64Core", .product(name: "AutoUpdateKit", package: "AutoUpdateKit")]
        ),
        .testTarget(
            name: "C64CoreTests",
            dependencies: ["C64Core"]
        ),
    ]
)
