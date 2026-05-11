// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThumbDrop",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "ThumbDrop", targets: ["ThumbDrop"]),
    ],
    targets: [
        .executableTarget(
            name: "ThumbDrop",
            path: "Sources/ThumbDrop"
        ),
    ]
)
