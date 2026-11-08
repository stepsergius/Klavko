// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Klavko",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Klavko", targets: ["Klavko"]),
    ],
    dependencies: [
        // On-device speech recognition (NVIDIA Parakeet on Core ML), for voice input.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        // Pure logic + keyboard layout maps. Testable without permissions.
        // Emoji/: emoji names in each language (scripts/make-emoji-data.py).
        .target(name: "KlavkoCore", resources: [.copy("Emoji")]),
        // The C API of sherpa-onnx (types only; the library is loaded at run time), for Cohere Transcribe.
        .target(name: "CSherpaOnnx"),
        // Menu bar app: event tap, text injection, UI.
        .executableTarget(name: "Klavko", dependencies: [
            "KlavkoCore",
            "CSherpaOnnx",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
        // Test helper: presses physical keys like a person typing in a given layout.
        .executableTarget(name: "KlavkoType", dependencies: ["KlavkoCore"]),
        .testTarget(name: "KlavkoCoreTests", dependencies: ["KlavkoCore"]),
    ],
    swiftLanguageModes: [.v5]
)
