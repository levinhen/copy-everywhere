// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyEverywhere",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CopyEverywhere",
            path: "Sources/CopyEverywhere"
        )
    ]
)
