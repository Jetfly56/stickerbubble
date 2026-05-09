import AppKit
import SwiftUI

/// Default sticker **frame** width (380pt panel − 18pt padding on each side). GIF uses 90% of this as layout width.
enum StickerCardLayout {
    static let defaultFrameWidth: CGFloat = 344

    /// Target width for raster / GIF content (90% of default frame width).
    static var mediaTargetWidth: CGFloat { defaultFrameWidth * 0.9 }
}

private enum MediaNaturalSize {
    static func logicalSize(for image: NSImage) -> CGSize {
        let s = image.size
        if s.width >= 2, s.height >= 2 {
            return s
        }

        var pixelW: CGFloat = 0
        var pixelH: CGFloat = 0
        for rep in image.representations {
            if let br = rep as? NSBitmapImageRep {
                pixelW = max(pixelW, CGFloat(br.pixelsWide))
                pixelH = max(pixelH, CGFloat(br.pixelsHigh))
            }
        }

        guard pixelW > 0, pixelH > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        return CGSize(width: pixelW / scale, height: pixelH / scale)
    }

    /// Display size: width = 90% of default frame; height from aspect ratio.
    static func displaySize(forBitmap image: NSImage) -> CGSize {
        let natural = logicalSize(for: image)
        let w = max(1, natural.width)
        let h = max(1, natural.height)
        let targetW = StickerCardLayout.mediaTargetWidth
        let targetH = targetW * (h / w)
        return CGSize(width: targetW, height: max(1, targetH))
    }
}

struct StickerDisplay: View {
    let source: StickerSource

    var body: some View {
        Group {
            switch source {
            case .url(let url):
                if let image = NSImage(contentsOf: url) {
                    let dims = MediaNaturalSize.displaySize(forBitmap: image)
                    AnimatedStickerImage(source: .url(url))
                        .frame(width: dims.width, height: dims.height)
                } else {
                    missing
                }

            case .image(let image):
                let dims = MediaNaturalSize.displaySize(forBitmap: image)
                AnimatedStickerImage(source: .image(image))
                    .frame(width: dims.width, height: dims.height)

            case .text(let string):
                textSticker(string)
            }
        }
    }

    private var missing: some View {
        Text("Could not load image")
            .foregroundStyle(.secondary)
            .padding(36)
            .frame(width: StickerCardLayout.mediaTargetWidth)
    }

    private func textSticker(_ string: String) -> some View {
        Text(string)
            .font(.system(size: Self.fontSize(forEmoji: string), design: .rounded))
            .multilineTextAlignment(.center)
            .lineLimit(nil)
            .minimumScaleFactor(0.35)
            .padding(24)
            .frame(width: StickerCardLayout.mediaTargetWidth, height: 220)
    }

    private static func fontSize(forEmoji text: String) -> CGFloat {
        let n = max(1, text.count)
        if n <= 2 { return 96 }
        if n <= 6 { return 72 }
        if n <= 14 { return 52 }
        return 36
    }
}

private enum AnimatedStickerSource {
    case url(URL)
    case image(NSImage)
}

private struct AnimatedStickerImage: NSViewRepresentable {
    let source: AnimatedStickerSource

    func makeNSView(context: Context) -> StickerSizedImageView {
        let view = StickerSizedImageView()
        configure(view)
        return view
    }

    func updateNSView(_ view: StickerSizedImageView, context: Context) {
        configure(view)
    }

    private func configure(_ view: StickerSizedImageView) {
        switch source {
        case .url(let u):
            view.image = NSImage(contentsOf: u)
        case .image(let img):
            view.image = img
        }
        view.animates = true
    }
}

private final class StickerSizedImageView: NSImageView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        imageScaling = .scaleProportionallyUpOrDown
        imageAlignment = .alignCenter
        animates = true
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
