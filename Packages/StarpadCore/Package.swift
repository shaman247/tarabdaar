// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "StarpadCore",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "StarpadCore", targets: ["StarpadCore"]),
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
            name: "StarpadCore",
            dependencies: ["SarangiKit"],
            path: "Sources/StarpadCore"
        ),
        .executableTarget(
            name: "paramdoc",
            dependencies: ["StarpadCore"],
            path: "Sources/paramdoc"
        ),
        .testTarget(
            name: "StarpadCoreTests",
            dependencies: ["StarpadCore"],
            path: "Tests/StarpadCoreTests"
        ),
    ]
)
