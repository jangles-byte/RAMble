// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RAMble",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "RAMble", targets: ["RAMble"]),
        .library(name: "RAMbleKit", targets: ["RAMbleKit"]),
    ],
    targets: [
        // Core: monitoring, state, stress, rendering, plugins, themes, app UI.
        .target(
            name: "RAMbleKit",
            path: "Sources/RAMbleKit",
            resources: [.copy("Resources/ram-logo.png")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Thin app entry point.
        .executableTarget(
            name: "RAMble",
            dependencies: ["RAMbleKit"],
            path: "Sources/RAMble",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Dependency-free verification runner: works on a bare Command Line
        // Tools install where XCTest/Swift Testing are unavailable.
        // Run with: swift run RAMbleSelfTest
        .executableTarget(
            name: "RAMbleSelfTest",
            dependencies: ["RAMbleKit"],
            path: "Sources/RAMbleSelfTest",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Standard Swift Testing suite; requires a full Xcode toolchain.
        .testTarget(
            name: "RAMbleTests",
            dependencies: ["RAMbleKit"],
            path: "Tests/RAMbleTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
