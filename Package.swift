// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mochi",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Mochi",
            path: "Sources/Mochi"
        ),
    ]
)
