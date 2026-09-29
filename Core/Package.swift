// swift-tools-version: 6.2
// TeleskooppiCore: platform-independent logic (Foundation only). Must build on Windows, Linux and iOS. See decisions.md D-03.
import PackageDescription

let package = Package(
    name: "TeleskooppiCore",
    platforms: [.iOS(.v26), .macOS(.v15)],
    products: [
        .library(name: "TeleskooppiCore", targets: ["TeleskooppiCore"]),
        .executable(name: "teleskooppi-cli", targets: ["teleskooppi-cli"]),
    ],
    targets: [
        .target(name: "TeleskooppiCore"),
        .executableTarget(name: "teleskooppi-cli", dependencies: ["TeleskooppiCore"]),
        .testTarget(name: "TeleskooppiCoreTests", dependencies: ["TeleskooppiCore"]),
    ]
)
