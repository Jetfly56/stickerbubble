// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StickerBubble",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .executable(name: "StickerBubble", targets: ["StickerBubble"]),
    ],
    targets: [
        .executableTarget(
            name: "StickerBubble",
            path: "Sources/StickerBubble"
        ),
    ]
)
