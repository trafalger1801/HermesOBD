// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "MustangOBD",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OBDMonitor", targets: ["OBDMonitor"]),
        .executable(name: "obd-cli", targets: ["obd-cli"]),
    ],
    targets: [
        // Protocol, decoding, safety guard, simulator, serial/TCP transports. No UI.
        .target(name: "OBDCore"),
        // SwiftUI desktop app (adds the Bluetooth LE transport).
        .executableTarget(name: "OBDMonitor", dependencies: ["OBDCore"]),
        // Headless tool for testing without the UI.
        .executableTarget(name: "obd-cli", dependencies: ["OBDCore"]),
        .testTarget(name: "OBDCoreTests", dependencies: ["OBDCore"]),
    ]
)
