// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceBrowser",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceBrowser", path: "Sources/VoiceBrowser"),
        .testTarget(name: "JarvisTests", dependencies: ["VoiceBrowser"], path: "Tests/JarvisTests"),
    ]
)
