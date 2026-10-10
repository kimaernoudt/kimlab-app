// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "KIMLAB",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "KIMLAB", path: "Sources/KIMLAB")
    ]
)
