// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TarabdaarCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "TarabdaarCore", targets: ["TarabdaarCore"]),
        // Build-time parameter-doc generator: renders docs/parameters.md
        // from the LIVE definitions (ParamRegistry, CompositeParam) so the
        // doc cannot drift from the code.
        // Run by tools/build-mac.sh on every CI build.
        .executable(name: "paramdoc", targets: ["paramdoc"]),
    ],
    dependencies: [
        .package(path: "../SarangiKit"),
    ],
    targets: [
        .target(
            name: "TarabdaarCore",
            dependencies: ["SarangiKit"],
            path: "Sources/TarabdaarCore"
        ),
        .executableTarget(
            name: "paramdoc",
            dependencies: ["TarabdaarCore"],
            path: "Sources/paramdoc"
        ),
        .testTarget(
            name: "TarabdaarCoreTests",
            dependencies: ["TarabdaarCore"],
            path: "Tests/TarabdaarCoreTests"
        ),
    ]
)
