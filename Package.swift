// swift-tools-version:6.0
import PackageDescription

// FujiCull: three targets with one-way dependencies (DESIGN §4, ADR-001).
// App -> Imaging -> Core. Core is Foundation + CryptoKit only.
let package = Package(
    name: "FujiCull",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FujiCull", targets: ["FujiCullApp"])
    ],
    targets: [
        .target(name: "FujiCullCore"),
        .target(name: "FujiCullImaging", dependencies: ["FujiCullCore"]),
        .executableTarget(name: "FujiCullApp", dependencies: ["FujiCullCore", "FujiCullImaging"]),
        .testTarget(name: "FujiCullCoreTests", dependencies: ["FujiCullCore"]),
        .testTarget(name: "FujiCullImagingTests", dependencies: ["FujiCullImaging"]),
    ]
)
