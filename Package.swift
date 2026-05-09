// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StickerPost",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "StickerPost", targets: ["StickerPost"]),
    ],
    targets: [
        .executableTarget(
            name: "StickerPost",
            path: "Sources/StickerPost"
        ),
    ]
)
