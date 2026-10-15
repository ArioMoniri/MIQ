// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MIQ",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "MIQCore",
            targets: ["MIQCore"]
        ),
        // `miq` command-line tool (info / render / mosaic). Not part of the app
        // bundle; build with `swift build -c release --product miq`.
        .executable(
            name: "miq",
            targets: ["miq"]
        )
    ],
    targets: [
        .target(
            name: "MIQCore"
        ),
        .executableTarget(
            name: "miq",
            dependencies: ["MIQCore"]
        ),
        .testTarget(
            name: "MIQCoreTests",
            dependencies: ["MIQCore"]
        ),
        .testTarget(
            name: "MIQCLITests",
            dependencies: ["miq", "MIQCore"]
        )
    ]
)
