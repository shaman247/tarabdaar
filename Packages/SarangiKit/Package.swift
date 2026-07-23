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
        // The bow-friction physics kernel: the SAME C source as the upstream
        // offline Python render (src/bowstring.py C_SRC), compiled in for
        // byte-exact parity (the 8-iteration Newton friction solve + thermal
        // state are too float-order-sensitive to re-derive in Swift).
        .target(
            name: "CBowKernel",
            path: "Sources/CBowKernel",
            // ALWAYS -O3: the offline reference dylib is `cc -O3`, and the
            // kernel dominates the live render (poly gut strings + modal-jawari
            // web + friction solves at 96 kHz) — a debug (-O0) kernel runs
            // several times below realtime.
            cSettings: [.unsafeFlags(["-O3"])]
        ),
        .target(
            name: "SarangiKit",
            dependencies: ["CBowKernel"],
            path: "Sources/SarangiKit",
            resources: [.process("Resources")],
            // Force full optimization even in Debug. `SarangiEngine.renderSample`
            // runs the whole passive coupled network (~78 web combs, two-pass
            // junction solve, modal body, 1025-tap radiation FIR) PER SAMPLE on
            // the audio thread; an unoptimized Debug build overruns the CPU
            // budget and the output chops into a scratchy "helicopter" of
            // buffer underruns. (Same reason StarpadDSP pins -O.)
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
