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
        .library(name: "HamlibRig", targets: ["HamlibRig"]),
        .executable(name: "ft8decode", targets: ["ft8decode"]),
        .executable(name: "ft8term", targets: ["ft8term"]),
        .executable(name: "ft8rig", targets: ["ft8rig"]),
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
        // Bundled Hamlib (LGPL), built by Scripts/build-hamlib.sh — link-only,
        // so end users never need `brew install hamlib`. Provides the dylib and
        // its runtime rpath; headers for the shim are vendored separately.
        .binaryTarget(
            name: "HamlibBinary",
            path: "Vendor/Hamlib.xcframework"
        ),
        // Clean C shim over Hamlib (mirrors the CFT8 pattern).
        .target(
            name: "CHamlib",
            dependencies: ["HamlibBinary"],
            path: "Sources/CHamlib",
            cSettings: [
                .headerSearchPath("vendor"), // resolves <hamlib/rig.h>
            ]
        ),
        // Headless engine: audio sources, decode orchestration, spectrum, rig.
        .target(
            name: "FT8808Engine",
            dependencies: ["FT8Codec"]
        ),
        // Swift-native Hamlib rig controller (implements RigController).
        .target(
            name: "HamlibRig",
            dependencies: ["CHamlib", "FT8808Engine"]
        ),
        // Milestone 0 spike: decode a WAV from the command line.
        .executableTarget(
            name: "ft8decode",
            dependencies: ["FT8Codec"]
        ),
        // Milestone 1: terminal FT8 client (SSH-friendly).
        .executableTarget(
            name: "ft8term",
            dependencies: ["FT8Codec", "FT8808Engine", "HamlibRig"],
            exclude: ["Info.plist"],
            linkerSettings: [
                // Embed an Info.plist so TCC can show a mic-permission prompt for
                // this CLI (live capture uses AVCaptureDevice).
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ft8term/Info.plist",
                ]),
            ]
        ),
        // Rig-control diagnostics.
        .executableTarget(
            name: "ft8rig",
            dependencies: ["FT8808Engine", "HamlibRig"]
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
            dependencies: ["FT8808Engine", "FT8Codec"],
            resources: [
                .copy("Resources"),
            ]
        ),
        .testTarget(
            name: "HamlibRigTests",
            dependencies: ["HamlibRig"]
        ),
    ]
)
