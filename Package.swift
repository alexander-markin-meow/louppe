// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Louppe",
    platforms: [.macOS(.v14)],
    targets: [
        // Use Sparkle's checksum-pinned public binary directly. This avoids a
        // source-control checkout (and therefore never needs GitHub credentials).
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.9.4/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "cb6fdbdc8884f15d62a616e79face92b08322410fd2d425edc6596ccbf4ba3b0"
        ),
        .executableTarget(
            name: "Louppe",
            dependencies: ["Sparkle"],
            path: "Sources/Louppe",
            linkerSettings: [
                // The release executable lives in Louppe.app/Contents/MacOS
                // and Sparkle is embedded in Louppe.app/Contents/Frameworks.
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
        .testTarget(
            name: "LouppeTests",
            dependencies: ["Louppe"],
            path: "Tests/LouppeTests"
        ),
    ]
)
