// swift-tools-version: 6.0
// macOS harness that runs the app's real engine sources (symlinked) end-to-end.
//   cd Tests/Harness && ./run.sh
import PackageDescription

let package = Package(
    name: "Harness",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.1"),
        .package(url: "https://github.com/FluidInference/FluidAudio", revision: "16780f04d2ece24f67d0fc00efccd0296491c1a8"),
    ],
    targets: [
        .executableTarget(
            name: "Harness",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Japanese/Korean speed + accuracy comparison: ./bench.sh
        .executableTarget(
            name: "Bench",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift"),
                           .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
