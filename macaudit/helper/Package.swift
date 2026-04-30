// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "macaudit-helper",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "macaudit-helper",
            path: "Sources/macaudit-helper"
        ),
        .testTarget(
            name: "macaudit-helperTests",
            dependencies: ["macaudit-helper"],
            path: "Tests/macaudit-helperTests"
        )
    ]
)
