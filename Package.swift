// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RawSignalProcessor",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "RawCore", targets: ["RawCore"]),
        .executable(name: "raw-bench", targets: ["RawBench"]),
    ],
    targets: [
        // Shared engine: pure-Swift colour math / metrics / settings, plus Core Image RAW decode
        // and Vision context analysis behind canImport guards.
        .target(name: "RawCore"),
        // macOS CLI: render, compare against Apple's default decode, batch benchmark.
        .executableTarget(name: "RawBench", dependencies: ["RawCore"]),
        .testTarget(
            name: "RawCoreTests",
            dependencies: ["RawCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
