// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MTPLXRouter",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MTPLXRouter",
            path: "Sources/MTPLXRouter"
        )
    ]
)
