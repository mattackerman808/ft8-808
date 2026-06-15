// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "FT8808",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "FT8Codec", targets: ["FT8Codec"]),
        .executable(name: "ft8decode", targets: ["ft8decode"]),
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
        // Milestone 0 spike: decode a WAV from the command line.
        .executableTarget(
            name: "ft8decode",
            dependencies: ["FT8Codec"]
        ),
        .testTarget(
            name: "FT8CodecTests",
            dependencies: ["FT8Codec"],
            resources: [
                .copy("Resources"),
            ]
        ),
    ]
)
