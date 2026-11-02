// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "nib",
    platforms: [.macOS("27.0")],   // HearthKit uses the macOS 27 third-party model API
    products: [
        .executable(name: "nib", targets: ["nib"]),
        .library(name: "NibCore", targets: ["NibCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/seckinbeduk/hearthkit", from: "0.1.0"),
    ],
    targets: [
        // Everything that doesn't need the model: diff parsing, budgeting, prompts, formatting, hooks.
        .target(name: "NibCore"),
        // The command-line tool, and the model: Apple Intelligence directly or through Hearth.
        .executableTarget(
            name: "nib",
            dependencies: [
                "NibCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "HearthKit", package: "hearthkit"),
            ]
        ),
        .testTarget(name: "NibCoreTests", dependencies: ["NibCore"]),
        // Error mapping in the executable target; builds error values, never calls a model.
        .testTarget(name: "NibTests", dependencies: ["nib", "NibCore"]),
    ]
)
