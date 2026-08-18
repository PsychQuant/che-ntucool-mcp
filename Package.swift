// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CheNtucoolMCP",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "CheNtucoolMCP",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            // Entitlements.plist is consumed by scripts/sign-and-notarize.sh at
            // release time, not compiled — exclude it so SwiftPM doesn't warn
            // about an unhandled resource.
            exclude: ["Entitlements.plist"]
        ),
        .testTarget(
            name: "CheNtucoolMCPTests",
            dependencies: [
                "CheNtucoolMCP",
                .product(name: "MCP", package: "swift-sdk")
            ]
        )
    ]
)
