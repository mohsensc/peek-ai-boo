// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PeekAiBoo",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "PeekCore"),
        .executableTarget(name: "PeekAiBoo", dependencies: ["PeekCore"]),
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"]),
    ]
)
