// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Write",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "Write", path: "Sources/Write")
    ]
)
