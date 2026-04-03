// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CloudflareAgents",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "CloudflareAgents", targets: ["CloudflareAgents"]),
    ],
    targets: [
        .target(
            name: "CloudflareAgents",
            path: "Sources/CloudflareAgents"
        ),
        .testTarget(
            name: "CloudflareAgentsTests",
            dependencies: ["CloudflareAgents"],
            path: "Tests/CloudflareAgentsTests"
        ),
    ]
)
