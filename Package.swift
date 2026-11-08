// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RawSignalProcessor",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RawCore", targets: ["RawCore"]),
        .library(name: "CaptureKit", targets: ["CaptureKit"]),
        .executable(name: "raw-bench", targets: ["RawBench"]),
    ],
    targets: [
        // Shared engine: pure-Swift colour math / metrics / settings, plus Core Image RAW decode
        // and Vision context analysis behind canImport guards.
        .target(name: "RawCore"),
        // iOS capture layer (AVFoundation Bayer RAW + HEIC from the same press). Compiles to metadata types only on macOS.
        .target(name: "CaptureKit"),
        // macOS CLI: render, compare against Apple's default decode, batch benchmark.
        .executableTarget(name: "RawBench", dependencies: ["RawCore"]),
        .testTarget(
            name: "RawCoreTests",
            dependencies: ["RawCore", "CaptureKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
