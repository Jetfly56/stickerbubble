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

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let canvasCornerRadius = size * 0.225

    // Rounded-square dark backdrop so the grey sticky note has contrast on light wallpapers.
    NSGraphicsContext.saveGraphicsState()
    let backdrop = NSBezierPath(roundedRect: canvas, xRadius: canvasCornerRadius, yRadius: canvasCornerRadius)
    backdrop.addClip()
    NSGradient(
        colors: [
            NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
            NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: canvas, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Sticky note geometry: centered, slight tilt, big peeled corner top-right.
    let notePadding = size * 0.14
    let noteRect = NSRect(
        x: notePadding,
        y: notePadding,
        width: size - notePadding * 2,
        height: size - notePadding * 2
    )
    let noteCornerRadius = size * 0.06
    let peelSize = size * 0.22

    // Slight rotation around note center for the "stuck on" look.
    let rotationDegrees: CGFloat = -4
    let center = NSPoint(x: noteRect.midX, y: noteRect.midY)

    NSGraphicsContext.saveGraphicsState()

    // Drop shadow for the note.
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.035
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    shadow.set()

    // Apply rotation around the note's center.
    let xform = NSAffineTransform()
    xform.translateX(by: center.x, yBy: center.y)
    xform.rotate(byDegrees: rotationDegrees)
    xform.translateX(by: -center.x, yBy: -center.y)
    xform.concat()

    // Note body — rounded rectangle with the top-right corner cut off (the peel).
    let bodyPath = stickyNoteBodyPath(rect: noteRect, cornerRadius: noteCornerRadius, peelSize: peelSize)

    // Subtle gradient on the note body for paper feel.
    NSGraphicsContext.saveGraphicsState()
    bodyPath.addClip()
    NSGradient(
        colors: [
            NSColor(red: 0.92, green: 0.93, blue: 0.94, alpha: 1),
            NSColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: noteRect, angle: -75)
    NSGraphicsContext.restoreGraphicsState()

    // Stop using shadow now that body is laid down.
    NSShadow().set()

    // Peel triangle (back of paper). Slightly darker than note + faint inner gradient.
    let peelPath = peelTrianglePath(rect: noteRect, peelSize: peelSize)
    NSGraphicsContext.saveGraphicsState()
    peelPath.addClip()
    let peelRect = NSRect(
        x: noteRect.maxX - peelSize,
        y: noteRect.maxY - peelSize,
        width: peelSize,
        height: peelSize
    )
    NSGradient(
        colors: [
            NSColor(red: 0.55, green: 0.57, blue: 0.60, alpha: 1),
            NSColor(red: 0.72, green: 0.74, blue: 0.77, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: peelRect, angle: -135)
    NSGraphicsContext.restoreGraphicsState()

    // Fold crease line along the diagonal of the peel.
    let crease = NSBezierPath()
    crease.move(to: NSPoint(x: noteRect.maxX - peelSize, y: noteRect.maxY))
    crease.line(to: NSPoint(x: noteRect.maxX, y: noteRect.maxY - peelSize))
    crease.lineWidth = max(1, size * 0.005)
    NSColor.black.withAlphaComponent(0.18).setStroke()
    crease.stroke()

    // Paper-plane send glyph, centered in the note (offset slightly away from the peel).
    drawSendGlyph(in: noteRect, peelSize: peelSize, size: size)

    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

func stickyNoteBodyPath(rect: NSRect, cornerRadius r: CGFloat, peelSize peel: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

    // Start at top-left corner (after rounding).
    path.move(to: NSPoint(x: minX + r, y: maxY))

    // Top edge → start of diagonal peel cut
    path.line(to: NSPoint(x: maxX - peel, y: maxY))

    // Diagonal cut for the peel
    path.line(to: NSPoint(x: maxX, y: maxY - peel))

    // Right edge → bottom-right corner
    path.line(to: NSPoint(x: maxX, y: minY + r))
    path.appendArc(
        withCenter: NSPoint(x: maxX - r, y: minY + r),
        radius: r,
        startAngle: 0, endAngle: -90, clockwise: true
    )

    // Bottom edge → bottom-left corner
    path.line(to: NSPoint(x: minX + r, y: minY))
    path.appendArc(
        withCenter: NSPoint(x: minX + r, y: minY + r),
        radius: r,
        startAngle: -90, endAngle: 180, clockwise: true
    )

    // Left edge → top-left corner
    path.line(to: NSPoint(x: minX, y: maxY - r))
    path.appendArc(
        withCenter: NSPoint(x: minX + r, y: maxY - r),
        radius: r,
        startAngle: 180, endAngle: 90, clockwise: true
    )

    path.close()
    return path
}

func peelTrianglePath(rect: NSRect, peelSize peel: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.maxX - peel, y: rect.maxY))
    path.line(to: NSPoint(x: rect.maxX - peel, y: rect.maxY - peel))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - peel))
    path.close()
    return path
}

func drawSendGlyph(in rect: NSRect, peelSize peel: CGFloat, size: CGFloat) {
    // Match the in-app send button: SF Symbol `paperplane.circle.fill`, hierarchical blue.
    let glyphPointSize = size * 0.50
    let sizeConfig = NSImage.SymbolConfiguration(pointSize: glyphPointSize, weight: .regular)
    let colorConfig = NSImage.SymbolConfiguration(hierarchicalColor: .systemBlue)
    let config = sizeConfig.applying(colorConfig)

    guard let symbol = NSImage(systemSymbolName: "paperplane.circle.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
    else { return }

    let symbolSize = symbol.size
    // Center the glyph on the note, biased away from the peel.
    let cx = rect.midX - peel * 0.15
    let cy = rect.midY - peel * 0.10
    let drawRect = NSRect(
        x: cx - symbolSize.width / 2,
        y: cy - symbolSize.height / 2,
        width: symbolSize.width,
        height: symbolSize.height
    )
    symbol.draw(in: drawRect)
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
