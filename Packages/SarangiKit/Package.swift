// swift-tools-version: 5.9
import PackageDescription

// Vendored from /Users/isha/Desktop/sarangi (the standalone sarangi model). Pure
// DSP + model — no CoreAudio / AVFoundation / CoreMIDI, so it builds on both the
// iOS and macOS Starpad targets (only macOS uses it, via StarpadCore.AudioEngine).
// Re-sync by recopying Sources/SarangiKit/{DSP,Model} + Resources from upstream.
let package = Package(
    name: "SarangiKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SarangiKit", targets: ["SarangiKit"]),
    ],
    targets: [
        .target(
            name: "SarangiKit",
            path: "Sources/SarangiKit",
            resources: [.process("Resources")],
            // Force full optimization even in Debug. `SarangiEngine.renderSample`
            // runs the whole 6-block chain (37 combs + 4× oversampled jawari +
            // 1025-tap FIR + Freeverb) PER SAMPLE on the audio thread; an
            // unoptimized Debug build overruns the CPU budget and the output
            // chops into a scratchy "helicopter" of buffer underruns. (Same
            // reason StarpadDSP pins -O.)
            swiftSettings: [
                .unsafeFlags(["-O"], .when(configuration: .debug)),
            ]
        ),
        .testTarget(
            name: "SarangiKitTests",
            dependencies: ["SarangiKit"],
            path: "Tests/SarangiKitTests",
            resources: [.copy("Goldens")]
        ),
    ]
)
