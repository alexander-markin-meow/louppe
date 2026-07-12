// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Louppe",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Louppe",
            path: "Sources/Louppe"
        )
    ]
)
