// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "nib",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "nib", targets: ["nib"]),
        .library(name: "NibCore", targets: ["NibCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        // Everything that doesn't need the model: diff parsing, budgeting, prompts, formatting, hooks.
        .target(name: "NibCore"),
        // The command-line tool and the Apple Intelligence backend.
        .executableTarget(
            name: "nib",
            dependencies: [
                "NibCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(name: "NibCoreTests", dependencies: ["NibCore"]),
    ]
)
