#!/usr/bin/swift
import AppKit
import Foundation

func makeIconPNG(pixelSize: Int) -> Data {
    let size = CGFloat(pixelSize)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225

    // Gradient background clipped to rounded rect
    let bgPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    NSGraphicsContext.saveGraphicsState()
    bgPath.addClip()
    NSGradient(
        colors: [
            NSColor(red: 0.18, green: 0.48, blue: 0.98, alpha: 1),
            NSColor(red: 0.55, green: 0.18, blue: 0.88, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: rect, angle: -50)
    NSGraphicsContext.restoreGraphicsState()

    // Speech bubble body
    let bInset = size * 0.16
    let bBottom = size * 0.22
    let bubbleRect = NSRect(
        x: bInset,
        y: bBottom,
        width: size - bInset * 2,
        height: size - bInset - bBottom - size * 0.04
    )
    NSColor.white.withAlphaComponent(0.96).setFill()
    NSBezierPath(roundedRect: bubbleRect, xRadius: size * 0.1, yRadius: size * 0.1).fill()

    // Bubble tail
    let tailMidX = bubbleRect.minX + bubbleRect.width * 0.3
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: tailMidX - size * 0.06, y: bubbleRect.minY + size * 0.01))
    tail.line(to: NSPoint(x: tailMidX + size * 0.06, y: bubbleRect.minY + size * 0.01))
    tail.line(to: NSPoint(x: tailMidX - size * 0.04, y: bubbleRect.minY - size * 0.09))
    tail.close()
    tail.fill()

    // Three colored dots
    let dotR = size * 0.07
    let dotY = bubbleRect.midY + size * 0.01
    for (i, color) in [
        NSColor(red: 1.0, green: 0.28, blue: 0.48, alpha: 1),
        NSColor(red: 1.0, green: 0.72, blue: 0.0,  alpha: 1),
        NSColor(red: 0.2, green: 0.82, blue: 0.46, alpha: 1)
    ].enumerated() {
        color.setFill()
        let dotX = bubbleRect.midX + CGFloat(i - 1) * dotR * 2.7
        NSBezierPath(ovalIn: NSRect(x: dotX - dotR, y: dotY - dotR, width: dotR * 2, height: dotR * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(name: String, logical: Int, scale: Int)] = [
    ("icon_16x16",      16,  1),
    ("icon_16x16@2x",   16,  2),
    ("icon_32x32",      32,  1),
    ("icon_32x32@2x",   32,  2),
    ("icon_128x128",    128, 1),
    ("icon_128x128@2x", 128, 2),
    ("icon_256x256",    256, 1),
    ("icon_256x256@2x", 256, 2),
    ("icon_512x512",    512, 1),
    ("icon_512x512@2x", 512, 2),
]

let dir = "AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

for e in entries {
    let pixels = e.logical * e.scale
    let data = makeIconPNG(pixelSize: pixels)
    let path = "\(dir)/\(e.name).png"
    try! data.write(to: URL(fileURLWithPath: path))
    print("  \(path)")
}
print("Done.")
