// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyEverywhereServer",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "CopyEverywhereServer",
            path: "Sources/CopyEverywhereServer"
        )
    ]
)
