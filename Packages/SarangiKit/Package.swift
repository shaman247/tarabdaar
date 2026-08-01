// swift-tools-version: 5.9
import PackageDescription

// The sarangi String voice: the bow-friction physics kernel, its table
// builders, the control mapper and the tarab document. Pure DSP + model — no
// CoreAudio / AVFoundation / CoreMIDI, so it builds on both the iOS and macOS
// Starpad targets (only macOS uses it, via StarpadCore.AudioEngine).
//
// This began as a vendored copy of the standalone model in ~/Desktop/sarangi
// and carried that project's whole surface — a coupled bridge–body network,
// an additive violin voice, a byte-parity mono kernel and their offline
// goldens. Starpad played none of it. The upstream link was cut on
// 2026-07-24 and everything that existed only to track it was deleted; what
// is left is what the instrument actually runs. There is no re-sync
// procedure any more — change the DSP here.
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
        // The bow-friction physics kernel, in C: the 8-iteration Newton
        // friction solve + thermal state are too float-order-sensitive to
        // re-derive in Swift.
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
            // Force full optimization even in Debug: the Swift side runs the
            // modal-jawari table builds and the whole post-chain (radiation
            // FIR, shelves, room) on the audio thread's budget, and an
            // unoptimized Debug build chops into buffer underruns.
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
