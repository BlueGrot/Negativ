// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Negativ",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Negativ", path: "Sources/Negativ")
    ]
)
