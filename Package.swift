// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mochi",
    platforms: [.macOS(.v26)],
    targets: [
        // 不碰界面的部分：认类型、存储。测试只依赖它。
        .target(
            name: "MochiCore",
            path: "Sources/MochiCore"
        ),
        .executableTarget(
            name: "Mochi",
            dependencies: ["MochiCore"],
            path: "Sources/Mochi"
        ),
        .testTarget(
            name: "MochiCoreTests",
            dependencies: ["MochiCore"],
            path: "Tests/MochiCoreTests"
        ),
    ]
)
