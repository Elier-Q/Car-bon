// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "frontend",
    platforms: [
        .macOS(.v11)
    ],
    targets: [
        .executableTarget(
            name: "frontend"
        )
    ]
)
