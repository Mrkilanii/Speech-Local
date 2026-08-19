// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SpeechLocal",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "SpeechLocalCore", targets: ["SpeechLocalCore"]),
    ],
    targets: [
        // Logic lives here so it is testable without a bundle or permissions.
        .target(name: "SpeechLocalCore"),
        // Thin executable; the .app bundle wraps this binary.
        .executableTarget(name: "SpeechLocal", dependencies: ["SpeechLocalCore"]),
        // Headless: raw PCM on stdin, one transcript on stdout. Kept apart from
        // the app target so nothing a second process does can disturb the
        // signed bundle's TCC identity.
        .executableTarget(name: "SpeechLocalStdin", dependencies: ["SpeechLocalCore"]),
        .testTarget(name: "SpeechLocalCoreTests", dependencies: ["SpeechLocalCore"]),
    ]
)
