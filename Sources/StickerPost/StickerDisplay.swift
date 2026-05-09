import AppKit
import SwiftUI
import WebKit

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
    @Binding var expanded: Bool

    var body: some View {
        Group {
            switch source {
            case .url(let url):
                if let service = MusicLinkService(url: url) {
                    MusicLinkCard(url: url, service: service)
                } else if let image = NSImage(contentsOf: url) {
                    let dims = MediaNaturalSize.displaySize(forBitmap: image)
                    let natural = MediaNaturalSize.logicalSize(for: image)
                    let isCropped = natural.width > dims.width + 0.5 || natural.height > dims.height + 0.5
                    AnimatedStickerImage(source: .url(url), scaling: expanded ? .scaleProportionallyUpOrDown : .scaleNone)
                        .frame(width: dims.width, height: dims.height)
                        .onTapGesture(count: 2) { expanded.toggle() }
                        .overlay(alignment: .topTrailing) {
                            if isCropped { scalingToggleButton }
                        }
                } else {
                    missing
                }

            case .image(let image):
                let dims = MediaNaturalSize.displaySize(forBitmap: image)
                let natural = MediaNaturalSize.logicalSize(for: image)
                let isCropped = natural.width > dims.width + 0.5 || natural.height > dims.height + 0.5
                AnimatedStickerImage(source: .image(image), scaling: expanded ? .scaleProportionallyUpOrDown : .scaleNone)
                    .frame(width: dims.width, height: dims.height)
                    .onTapGesture(count: 2) { expanded.toggle() }
                    .overlay(alignment: .topTrailing) {
                        if isCropped { scalingToggleButton }
                    }

            case .text(let string):
                textSticker(string)
            }
        }
    }

    private var scalingToggleButton: some View {
        Button {
            expanded.toggle()
        } label: {
            Image(systemName: expanded ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .diffuseCircleBackdrop(size: 26)
        }
        .buttonStyle(.plain)
        .help(expanded ? "Show at natural size" : "Scale to fit frame")
        .padding(6)
    }

    private var missing: some View {
        Text("Could not load image")
            .foregroundStyle(.secondary)
            .padding(36)
            .frame(width: StickerCardLayout.mediaTargetWidth)
    }

    @ViewBuilder
    private func textSticker(_ string: String) -> some View {
        switch Self.classify(string) {
        case .code:
            Text(Self.stripCodeFences(string))
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
                .lineLimit(nil)
                .padding(14)
                .frame(width: StickerCardLayout.mediaTargetWidth, height: 280, alignment: .topLeading)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.78))
                }
                .foregroundStyle(Color(white: 0.92))
                .clipped()
                .allowsHitTesting(false)
        case .formula:
            LatexFormulaView(source: Self.stripFormulaFences(string))
                .frame(width: StickerCardLayout.mediaTargetWidth, height: 180)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.35))
                }
                .allowsHitTesting(false)
        case .plain:
            Text(string)
                .font(.system(size: Self.fontSize(forEmoji: string), design: .rounded))
                .multilineTextAlignment(.center)
                .lineLimit(nil)
                .minimumScaleFactor(0.35)
                .padding(24)
                .frame(width: StickerCardLayout.mediaTargetWidth, height: 220)
        }
    }

    enum TextStickerKind { case code, formula, plain }

    private static func stripCodeFences(_ text: String) -> String {
        var s = text
        if s.hasPrefix("```\n") { s.removeFirst(4) } else if s.hasPrefix("```") { s.removeFirst(3) }
        if s.hasSuffix("\n```") { s.removeLast(4) } else if s.hasSuffix("```") { s.removeLast(3) }
        return s
    }

    private static func stripFormulaFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("$$") { s.removeFirst(2) }
        if s.hasSuffix("$$") { s.removeLast(2) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func classify(_ text: String) -> TextStickerKind {
        if text.contains("```") { return .code }
        if text.contains("$$") { return .formula }
        return .plain
    }

    /// Auto-detect kind for paste-time wrapping. Conservative — only wraps when there are strong signals.
    static func autoDetectKind(_ text: String) -> TextStickerKind {
        let latexCommands = ["\\frac", "\\sum", "\\int", "\\sqrt", "\\prod", "\\lim",
                             "\\binom", "\\begin{", "\\end{", "\\left", "\\right",
                             "\\infty", "\\partial", "\\nabla", "\\cdot", "\\times",
                             "\\leq", "\\geq", "\\neq", "\\approx"]
        if latexCommands.contains(where: { text.contains($0) }) { return .formula }

        if text.contains("\n") {
            let codeMarkers = ["{", "}", ";", "->", "=>", "    ", "\t",
                               "function ", "def ", "class ", "import ", "return ",
                               "if (", "for (", "while (", "var ", "let ", "const ", "func ",
                               "public ", "private ", "fileprivate ", "internal ", "extension ",
                               "struct ", "enum ", "protocol ", "guard ", "switch ", "case ",
                               "#include", "#import", "package ", "async ", "await ",
                               "fn ", "use ", "lambda "]
            if codeMarkers.contains(where: { text.contains($0) }) { return .code }
        }

        return .plain
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
    var scaling: NSImageScaling = .scaleNone

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
        view.imageScaling = scaling
        view.useFrameAsAuthoritativeSize = (scaling != .scaleNone)
        view.invalidateIntrinsicContentSize()
        view.animates = true
    }
}

private final class StickerSizedImageView: NSImageView {
    var useFrameAsAuthoritativeSize = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        imageAlignment = .alignCenter
        animates = true
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        if useFrameAsAuthoritativeSize {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
        return super.intrinsicContentSize
    }
}

struct LatexFormulaView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> NonFocusingWebView {
        let view = NonFocusingWebView()
        view.setValue(false, forKey: "drawsBackground")
        view.loadHTMLString(Self.html(for: source), baseURL: URL(string: "https://cdn.jsdelivr.net"))
        return view
    }

    func updateNSView(_ view: NonFocusingWebView, context: Context) {
        view.loadHTMLString(Self.html(for: source), baseURL: URL(string: "https://cdn.jsdelivr.net"))
    }

    private static func html(for source: String) -> String {
        let json = (try? JSONSerialization.data(withJSONObject: [source], options: [])).flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let jsonLiteral = String(json.dropFirst().dropLast())
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="UTF-8">
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.css">
        <style>
          html, body { margin: 0; padding: 0; height: 100%; background: transparent; color: #f0f0f0; -webkit-user-select: text; }
          body { display: flex; align-items: center; justify-content: center; padding: 14px; box-sizing: border-box; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
          #math { max-width: 100%; max-height: 100%; overflow: auto; text-align: center; }
          .katex { color: #f0f0f0; font-size: 1.4em; }
          .katex-display { margin: 0; }
          .fallback { font-family: 'Times New Roman', serif; font-style: italic; font-size: 22px; white-space: pre-wrap; }
        </style>
        <script>
          window.__renderMath = function() {
            if (typeof katex === 'undefined') return;
            try {
              katex.render(\(jsonLiteral), document.getElementById('math'), {
                displayMode: true, throwOnError: false, output: 'html'
              });
            } catch (e) { /* leave fallback */ }
          };
        </script>
        <script src="https://cdn.jsdelivr.net/npm/katex@0.16.9/dist/katex.min.js" onload="window.__renderMath && window.__renderMath()" onerror="/* leave fallback */"></script>
        </head>
        <body>
        <div id="math"><span class="fallback">\(htmlEscape(source))</span></div>
        <script>
          if (typeof katex !== 'undefined') { window.__renderMath(); }
        </script>
        </body>
        </html>
        """
    }

    private static func htmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

final class NonFocusingWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
}
