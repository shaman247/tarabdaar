// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StarpadDSP",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "StarpadDSP", targets: ["StarpadDSP"]),
        // Offline tanpura renderer used by the autonomous matching loop
        // (tools/tanpura_iterate.py). Renders a JSON spec to WAV far
        // faster than real time, no app or audio hardware needed.
        .executable(name: "tanpura-render", targets: ["TanpuraRender"]),
    ],
    targets: [
        .executableTarget(
            name: "TanpuraRender",
            dependencies: ["StarpadDSP"],
            path: "Sources/TanpuraRender"
        ),
        .target(
            name: "StarpadDSP",
            path: "Sources/StarpadDSP",
            // Force full optimization even when host app is in Debug.
            // The DSP runs on the audio thread; without -O the inner mode
            // loops fall back to scalar and the inner-loop closure capture
            // isn't inlined, so a Debug build can hit CPU limits.
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "StarpadDSPTests",
            dependencies: ["StarpadDSP"],
            path: "Tests/StarpadDSPTests"
        ),
    ]
)
