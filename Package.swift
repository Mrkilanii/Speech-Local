// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FlowLocal",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FlowLocalCore", targets: ["FlowLocalCore"]),
    ],
    targets: [
        // Logic lives here so it is testable without a bundle or permissions.
        .target(name: "FlowLocalCore"),
        // Thin executable; the .app bundle wraps this binary.
        .executableTarget(name: "FlowLocal", dependencies: ["FlowLocalCore"]),
        .testTarget(name: "FlowLocalCoreTests", dependencies: ["FlowLocalCore"]),
    ]
)
