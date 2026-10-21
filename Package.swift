// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Clipboard",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Clipboard",
            path: "Sources/Clipboard"
        ),
    ]
)
