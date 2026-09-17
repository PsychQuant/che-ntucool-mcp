// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheNtucoolMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CheNtucoolCore", targets: ["CheNtucoolCore"]),
        .executable(name: "CheNtucoolMCP", targets: ["CheNtucoolMCP"]),
        .executable(name: "che-ntucool", targets: ["che-ntucool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        // Shared Canvas client: models, transport ladder (token → Safari
        // session), keychain access, course config. Both executables build on
        // this so there is exactly one implementation of "talk to NTU COOL".
        .target(
            name: "CheNtucoolCore"
        ),
        .executableTarget(
            name: "CheNtucoolMCP",
            dependencies: [
                "CheNtucoolCore",
                .product(name: "MCP", package: "swift-sdk"),
            ],
            // Entitlements.plist is consumed by scripts/sign-and-notarize.sh at
            // release time, not compiled — exclude it so SwiftPM doesn't warn
            // about an unhandled resource.
            exclude: ["Entitlements.plist"]
        ),
        .executableTarget(
            name: "che-ntucool",
            dependencies: [
                "CheNtucoolCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/CheNtucool"
        ),
        .testTarget(
            name: "CheNtucoolCoreTests",
            dependencies: ["CheNtucoolCore"]
        ),
        .testTarget(
            name: "CheNtucoolMCPTests",
            dependencies: [
                "CheNtucoolMCP",
                "CheNtucoolCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
