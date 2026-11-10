// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TS3Kit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "TS3Kit", targets: ["TS3Kit"]),
        .library(name: "TS3Audio", targets: ["TS3Audio"]),
        .executable(name: "ts3probe", targets: ["ts3probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.4.0"),
        .package(url: "https://github.com/alta/swift-opus.git", from: "0.0.2"),
    ],
    targets: [
        // Ed25519 group arithmetic (ref10 via orlp/ed25519, zlib licence) for the license key chain.
        // Also the fixed-size modular squaring for the handshake puzzle (ts_modpow).
        .target(
            name: "CEd25519",
            exclude: ["LICENSE-ed25519.txt"]
        ),
        // Protocol, crypto, command layer and the observable server state.
        .target(
            name: "TS3Kit",
            dependencies: [
                "CEd25519",
                .product(name: "BigInt", package: "BigInt"),
            ]
        ),
        // Callable wrappers for the variadic opus_encoder_ctl.
        .target(
            name: "COpusShim",
            dependencies: [.product(name: "Copus", package: "swift-opus")]
        ),
        // Opus voice capture and playback.
        .target(
            name: "TS3Audio",
            dependencies: [
                "TS3Kit",
                "COpusShim",
                .product(name: "Copus", package: "swift-opus"),
            ]
        ),
        // CLI used to verify the protocol against a live server.
        .executableTarget(
            name: "ts3probe",
            dependencies: ["TS3Kit"]
        ),
        .testTarget(
            name: "TS3KitTests",
            dependencies: ["TS3Kit", "TS3Audio", "CEd25519"]
        ),
    ]
)
