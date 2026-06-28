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
    ],
    dependencies: [
        .package(path: "../StarpadDSP"),
        .package(path: "../SarangiKit"),
    ],
    targets: [
        .target(
            name: "StarpadCore",
            dependencies: ["StarpadDSP", "SarangiKit"],
            path: "Sources/StarpadCore"
        ),
    ]
)
