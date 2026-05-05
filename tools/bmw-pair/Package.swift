// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BMWPair",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "BMWPair", path: "Sources/BMWPair")
    ]
)
