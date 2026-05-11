#!/usr/bin/swift
import AppKit
import Foundation

struct SeededRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
    mutating func nextDouble() -> Double {
        return Double(next() >> 11) / Double(1 << 53)
    }
}

func gumdropPath(in rect: NSRect) -> NSBezierPath {
    let path = NSBezierPath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    let w = rect.width, h = rect.height
    let midX = rect.midX
    let baseR: CGFloat = w * 0.10

    path.move(to: NSPoint(x: minX + baseR, y: minY))
    path.appendArc(
        withCenter: NSPoint(x: minX + baseR, y: minY + baseR),
        radius: baseR,
        startAngle: -90, endAngle: 180, clockwise: true
    )
    path.curve(
        to: NSPoint(x: midX, y: maxY),
        controlPoint1: NSPoint(x: minX, y: minY + h * 0.62),
        controlPoint2: NSPoint(x: midX - w * 0.34, y: maxY)
    )
    path.curve(
        to: NSPoint(x: maxX, y: minY + baseR),
        controlPoint1: NSPoint(x: midX + w * 0.34, y: maxY),
        controlPoint2: NSPoint(x: maxX, y: minY + h * 0.62)
    )
    path.appendArc(
        withCenter: NSPoint(x: maxX - baseR, y: minY + baseR),
        radius: baseR,
        startAngle: 0, endAngle: -90, clockwise: true
    )
    path.line(to: NSPoint(x: minX + baseR, y: minY))
    path.close()
    return path
}

func stickyNoteBodyPath(rect: NSRect, cornerRadius r: CGFloat, peelSize peel: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY

    path.move(to: NSPoint(x: minX + r, y: maxY))
    path.line(to: NSPoint(x: maxX - peel, y: maxY))
    path.line(to: NSPoint(x: maxX, y: maxY - peel))
    path.line(to: NSPoint(x: maxX, y: minY + r))
    path.appendArc(
        withCenter: NSPoint(x: maxX - r, y: minY + r),
        radius: r,
        startAngle: 0, endAngle: -90, clockwise: true
    )
    path.line(to: NSPoint(x: minX + r, y: minY))
    path.appendArc(
        withCenter: NSPoint(x: minX + r, y: minY + r),
        radius: r,
        startAngle: -90, endAngle: 180, clockwise: true
    )
    path.line(to: NSPoint(x: minX, y: maxY - r))
    path.appendArc(
        withCenter: NSPoint(x: minX + r, y: maxY - r),
        radius: r,
        startAngle: 180, endAngle: 90, clockwise: true
    )
    path.close()
    return path
}

func peelTrianglePath(rect: NSRect, peelSize peel: CGFloat, cornerRadius r: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let foldTop = NSPoint(x: rect.maxX - peel, y: rect.maxY)
    let inner   = NSPoint(x: rect.maxX - peel, y: rect.maxY - peel)
    let foldRight = NSPoint(x: rect.maxX, y: rect.maxY - peel)

    path.move(to: foldTop)
    path.line(to: NSPoint(x: inner.x, y: inner.y + r))
    path.appendArc(
        withCenter: NSPoint(x: inner.x + r, y: inner.y + r),
        radius: r,
        startAngle: 180, endAngle: 270, clockwise: false
    )
    path.line(to: foldRight)
    path.close()
    return path
}

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
    let canvasR = size * 0.225

    // Dark rounded backdrop
    NSGraphicsContext.saveGraphicsState()
    let outerShape = NSBezierPath(roundedRect: canvas, xRadius: canvasR, yRadius: canvasR)
    outerShape.addClip()
    NSGradient(
        colors: [
            NSColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1),
            NSColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: canvas, angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Sticky note geometry — inset, tilted, with peeled top-right corner
    let notePadding = size * 0.14
    let noteRect = NSRect(
        x: notePadding,
        y: notePadding,
        width: size - notePadding * 2,
        height: size - notePadding * 2
    )
    let noteCornerRadius = size * 0.06
    let peelSize = size * 0.22
    let rotationDegrees: CGFloat = -4
    let noteCenter = NSPoint(x: noteRect.midX, y: noteRect.midY)

    NSGraphicsContext.saveGraphicsState()

    // Drop shadow for the note
    let noteShadow = NSShadow()
    noteShadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    noteShadow.shadowBlurRadius = size * 0.035
    noteShadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
    noteShadow.set()

    // Rotate around the note center
    let xform = NSAffineTransform()
    xform.translateX(by: noteCenter.x, yBy: noteCenter.y)
    xform.rotate(byDegrees: rotationDegrees)
    xform.translateX(by: -noteCenter.x, yBy: -noteCenter.y)
    xform.concat()

    // Note body
    let note = stickyNoteBodyPath(rect: noteRect, cornerRadius: noteCornerRadius, peelSize: peelSize)
    NSGraphicsContext.saveGraphicsState()
    note.addClip()
    NSGradient(
        colors: [
            NSColor(red: 0.92, green: 0.93, blue: 0.94, alpha: 1),
            NSColor(red: 0.78, green: 0.80, blue: 0.83, alpha: 1)
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )!.draw(in: noteRect, angle: -75)
    NSGraphicsContext.restoreGraphicsState()

    // Stop using shadow now that body is down
    NSShadow().set()

    // Ink palette for the gumdrop
    let outline = NSColor(red: 0.78, green: 0.20, blue: 0.16, alpha: 1)
    let body    = NSColor(red: 0.93, green: 0.31, blue: 0.28, alpha: 1)
    let sugar   = NSColor(red: 1.00, green: 0.76, blue: 0.74, alpha: 1)
    let sheen   = NSColor(red: 1.00, green: 0.84, blue: 0.82, alpha: 1)

    // Gumdrop geometry — fills more of the note so it tucks under the peel
    let gumdropInset = size * 0.04
    let gumdropRect = NSRect(
        x: noteRect.minX + gumdropInset,
        y: noteRect.minY + gumdropInset,
        width: noteRect.width - gumdropInset * 2,
        height: noteRect.height - gumdropInset * 2
    )

    // Behind-shape (offset down-right, outline color)
    let backOffset = size * 0.014
    let backInflate = size * 0.014
    let backRect = NSRect(
        x: gumdropRect.minX - backInflate + backOffset,
        y: gumdropRect.minY - backInflate - backOffset,
        width: gumdropRect.width + backInflate * 2,
        height: gumdropRect.height + backInflate * 2
    )
    let backShape = gumdropPath(in: backRect)
    NSGraphicsContext.saveGraphicsState()
    let gumdropShadow = NSShadow()
    gumdropShadow.shadowOffset = NSSize(width: 0, height: -size * 0.008)
    gumdropShadow.shadowBlurRadius = size * 0.020
    gumdropShadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    gumdropShadow.set()
    outline.setFill()
    backShape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Outline ring + body
    let strokeWidth = size * 0.025
    let outlineRect = gumdropRect.insetBy(dx: -strokeWidth * 0.5, dy: -strokeWidth * 0.5)
    outline.setFill()
    gumdropPath(in: outlineRect).fill()

    let gumdrop = gumdropPath(in: gumdropRect)
    body.setFill()
    gumdrop.fill()

    // Decorations clipped to the body
    NSGraphicsContext.saveGraphicsState()
    gumdrop.addClip()

    // Curved sheen highlight
    let sheenPath = NSBezierPath()
    let sx1 = gumdropRect.midX - gumdropRect.width * 0.20
    let sy1 = gumdropRect.maxY - gumdropRect.height * 0.10
    let sx2 = gumdropRect.midX - gumdropRect.width * 0.28
    let sy2 = gumdropRect.midY + gumdropRect.height * 0.05
    sheenPath.move(to: NSPoint(x: sx1, y: sy1))
    sheenPath.curve(
        to: NSPoint(x: sx2, y: sy2),
        controlPoint1: NSPoint(x: sx1 - gumdropRect.width * 0.15, y: sy1 - gumdropRect.height * 0.15),
        controlPoint2: NSPoint(x: sx2 + gumdropRect.width * 0.02, y: sy2 + gumdropRect.height * 0.15)
    )
    sheenPath.lineWidth = size * 0.030
    sheenPath.lineCapStyle = .round
    sheen.setStroke()
    sheenPath.stroke()

    // Uniform sugar dots
    var rng = SeededRNG(state: 0xC0FFEEDEADBEEF)
    let dotRadius = size * 0.016
    let cols = 9
    let rows = 11
    let cellW = gumdropRect.width / CGFloat(cols)
    let cellH = gumdropRect.height / CGFloat(rows)
    let jitter = min(cellW, cellH) * 0.35

    for row in 0..<rows {
        for col in 0..<cols {
            let baseX = gumdropRect.minX + (CGFloat(col) + 0.5) * cellW
            let baseY = gumdropRect.minY + (CGFloat(row) + 0.5) * cellH
            let jx = (rng.nextDouble() - 0.5) * Double(jitter * 2)
            let jy = (rng.nextDouble() - 0.5) * Double(jitter * 2)
            let x = baseX + CGFloat(jx)
            let y = baseY + CGFloat(jy)

            if !gumdrop.contains(NSPoint(x: x, y: y)) { continue }
            let dxs = x - sx2
            let dys = y - sy2
            if dxs * dxs + dys * dys < pow(gumdropRect.width * 0.10, 2) { continue }
            if rng.nextDouble() < 0.08 { continue }

            let dot = NSBezierPath(ovalIn: NSRect(
                x: x - dotRadius, y: y - dotRadius,
                width: dotRadius * 2, height: dotRadius * 2
            ))
            sugar.setFill()
            dot.fill()
        }
    }

    NSGraphicsContext.restoreGraphicsState() // gumdrop clip

    // Peel triangle (back of paper) — drawn AFTER gumdrop so it overlays the corner
    let peel = peelTrianglePath(rect: noteRect, peelSize: peelSize)

    // Subtle shadow cast by the peel onto the gumdrop/note below
    NSGraphicsContext.saveGraphicsState()
    let peelShadow = NSShadow()
    peelShadow.shadowOffset = NSSize(width: -size * 0.006, height: -size * 0.010)
    peelShadow.shadowBlurRadius = size * 0.020
    peelShadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
    peelShadow.set()
    // Fill with the base peel color first so the shadow has an opaque source
    NSColor(red: 0.62, green: 0.64, blue: 0.67, alpha: 1).setFill()
    peel.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Gradient on the peel for the folded-paper underside
    NSGraphicsContext.saveGraphicsState()
    peel.addClip()
    let peelRect = NSRect(
        x: noteRect.maxX - peelSize, y: noteRect.maxY - peelSize,
        width: peelSize, height: peelSize
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

    // Crease line along the fold
    let crease = NSBezierPath()
    crease.move(to: NSPoint(x: noteRect.maxX - peelSize, y: noteRect.maxY))
    crease.line(to: NSPoint(x: noteRect.maxX, y: noteRect.maxY - peelSize))
    crease.lineWidth = max(1, size * 0.005)
    NSColor.black.withAlphaComponent(0.25).setStroke()
    crease.stroke()

    NSGraphicsContext.restoreGraphicsState() // rotation/shadow
    NSGraphicsContext.restoreGraphicsState() // outer
    return rep.representation(using: .png, properties: [:])!
}

let data = makeIconPNG(pixelSize: 512)
let outPath = "AppIcon.preview.png"
try! data.write(to: URL(fileURLWithPath: outPath))
print("Wrote \(outPath)")
