// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FT8808",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FT8Codec", targets: ["FT8Codec"]),
        .library(name: "FT8808Engine", targets: ["FT8808Engine"]),
        .executable(name: "ft8decode", targets: ["ft8decode"]),
        .executable(name: "ft8term", targets: ["ft8term"]),
    ],
    targets: [
        // Vendored kgoba/ft8_lib (MIT) plus the FT8-808 C shim.
        .target(
            name: "CFT8",
            path: "Sources/CFT8",
            exclude: [
                "ft8_lib.LICENSE.txt",
            ],
            publicHeadersPath: "include",
            cSettings: [
                // Lets the vendored sources resolve <ft8/...>, <common/...>, <fft/...>.
                .headerSearchPath("."),
            ]
        ),
        // Swift-native wrapper over the C shim.
        .target(
            name: "FT8Codec",
            dependencies: ["CFT8"]
        ),
        // Headless engine: audio sources, decode orchestration, spectrum, rig.
        .target(
            name: "FT8808Engine",
            dependencies: ["FT8Codec"]
        ),
        // Milestone 0 spike: decode a WAV from the command line.
        .executableTarget(
            name: "ft8decode",
            dependencies: ["FT8Codec"]
        ),
        // Milestone 1: terminal FT8 client (SSH-friendly).
        .executableTarget(
            name: "ft8term",
            dependencies: ["FT8Codec", "FT8808Engine"]
        ),
        .testTarget(
            name: "FT8CodecTests",
            dependencies: ["FT8Codec"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "FT8808EngineTests",
            dependencies: ["FT8808Engine"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
