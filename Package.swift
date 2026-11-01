// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GlassIsland",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "GlassIsland",
            path: "Sources/GlassIsland",
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "GlassIslandTests",
            dependencies: ["GlassIsland"],
            path: "Tests/GlassIslandTests"
        )
    ]
)
