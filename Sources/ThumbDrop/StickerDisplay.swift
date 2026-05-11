import AppKit
import SwiftUI
import WebKit

/// Default sticker **frame** width (380pt panel − 18pt padding on each side). GIF uses 90% of this as layout width.
enum StickerCardLayout {
    static let defaultFrameWidth: CGFloat = 344

    /// Target width for raster / GIF content (90% of default frame width).
    static var mediaTargetWidth: CGFloat { defaultFrameWidth * 0.9 }
}

enum MediaNaturalSize {
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
    /// Reference holder shared with `BubbleModel`. The canvas writes directly to this in
    /// its mouse / pinch / scroll handlers, bypassing `@Published`, so transforms during
    /// gestures don't re-render the rest of the bubble.
    var transform: StickerTransformHolder = StickerTransformHolder()
    /// Bumped by the model when something *external* changes the holder (e.g. an inbox
    /// message being loaded into the bubble, or a zoom button click). The canvas wrapper
    /// observes this via `updateNSView` and re-applies the holder transform.
    var transformNonce: Int = 0
    /// Flips the bubble into a stripped-down editing mode.
    var isEditing: Binding<Bool> = .constant(false)
    /// Bumps the model's `stickerTransformNonce` so views observing the nonce (e.g. the
    /// zoom slider) resync from the holder when the canvas finishes a continuous gesture.
    var onTransformBumped: () -> Void = {}

    @State private var canvasController = StickerCanvasController()

    var body: some View {
        Group {
            switch source {
            case .url(let url):
                if let service = MusicLinkService(url: url) {
                    MusicLinkCard(url: url, service: service)
                } else if let image = NSImage(contentsOf: url) {
                    canvasImage(image)
                } else {
                    missing
                }

            case .image(let image):
                canvasImage(image)

            case .text(let string):
                textSticker(string)
            }
        }
    }

    // MARK: - Image rendering via the AppKit canvas

    @ViewBuilder
    private func canvasImage(_ image: NSImage) -> some View {
        let dims = MediaNaturalSize.displaySize(forBitmap: image)
        let natural = MediaNaturalSize.logicalSize(for: image)
        let naturallyOversized = natural.width > dims.width + 0.5 || natural.height > dims.height + 0.5
        let canShowControls = naturallyOversized || isEditing.wrappedValue || transform.scale > 1.0 + 0.001

        StickerCanvasView(
            image: image,
            naturalSize: natural,
            frameSize: dims,
            transform: transform,
            nonce: transformNonce,
            isEditing: isEditing.wrappedValue,
            animates: !isEditing.wrappedValue,
            expanded: expanded,
            // Double-click is handled inside the canvas via `event.clickCount == 2`, not
            // by a SwiftUI tap gesture — that gesture sits on the initial mouseDown to
            // disambiguate, making drags feel laggy.
            onDoubleClick: { expanded.toggle() },
            onInteractionEnded: onTransformBumped,
            controller: canvasController
        )
        .frame(width: dims.width, height: dims.height)
        .overlay(alignment: .topTrailing) {
            if canShowControls {
                VStack(spacing: 6) {
                    if !expanded {
                        zoomButton(
                            systemName: isEditing.wrappedValue ? "checkmark.circle.fill" : "pencil.circle.fill",
                            help: isEditing.wrappedValue ? "Done editing" : "Edit pan & zoom"
                        ) {
                            isEditing.wrappedValue.toggle()
                        }
                        // Slider only visible in edit mode — pan/zoom are locked otherwise.
                        if isEditing.wrappedValue {
                            zoomSlider(natural: natural, dims: dims)
                        }
                    }
                    // Scale-to-fit toggle hides in edit mode (incompatible with explicit
                    // pan/zoom) but is still shown for normal viewing and for revert.
                    if !isEditing.wrappedValue {
                        scalingToggleButton
                    }
                }
                .padding(6)
            }
        }
    }

    /// Vertical zoom slider. The slider's binding writes scale through the
    /// `StickerCanvasController`, which calls into the canvas directly — bypassing
    /// `@Published` state so a slider drag updates the CALayer transform without
    /// re-rendering the rest of the bubble.
    ///
    /// `transform.scale` is read on body re-evaluation to drive the visual thumb position.
    /// Body re-evaluates whenever `transformNonce` bumps (after a drag/pinch/scroll ends),
    /// so the thumb resyncs after non-slider gestures. The slider's low end is clamped to
    /// the fit-to-frame scale so zooming out can't shrink the image smaller than the
    /// viewer (matches the canvas's `effectiveMinScale`).
    private func zoomSlider(natural: CGSize, dims: CGSize) -> some View {
        let fit = dims.width / max(natural.width, 1)
        let minS = Double(min(1.0, max(StickerCanvasNSView.minScale, fit)))
        let maxS = Double(StickerCanvasNSView.maxScale)
        return Slider(
            value: Binding<Double>(
                get: { Double(transform.scale).clamped(minS, maxS) },
                set: { newVal in canvasController.setScale(CGFloat(newVal)) }
            ),
            in: minS ... maxS
        )
        .controlSize(.mini)
        .frame(width: 90)
        .rotationEffect(.degrees(-90))
        .frame(width: 26, height: 96)
        .help("Zoom")
    }

    private func zoomButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .background {
                    Circle()
                        .fill(Color(white: 0.0, opacity: 0.35))
                        .frame(width: 26, height: 26)
                        .allowsHitTesting(false)
                }
        }
        .buttonStyle(.plain)
        .help(help)
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

    // MARK: - Text stickers (unchanged)

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

    /// Peels any of `$$…$$`, `\[…\]`, `\(…\)`, or `$…$` (in any order, possibly nested)
    /// so KaTeX receives raw math without surrounding delimiters.
    private static func stripFormulaFences(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(String, String)] = [("$$", "$$"), ("\\[", "\\]"), ("\\(", "\\)")]
        var changed = true
        while changed {
            changed = false
            for (open, close) in pairs where s.hasPrefix(open) && s.hasSuffix(close) && s.count >= open.count + close.count {
                s = String(s.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
            if !changed, s.count >= 2, s.hasPrefix("$"), s.hasSuffix("$"), !s.hasPrefix("$$") {
                s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
            }
        }
        return s
    }

    static func classify(_ text: String) -> TextStickerKind {
        if text.contains("```") { return .code }
        if text.contains("$$") { return .formula }
        if text.contains("\\[") && text.contains("\\]") { return .formula }
        if text.contains("\\(") && text.contains("\\)") { return .formula }
        if isLikelyCode(text) { return .code }
        if isLikelyFormula(text) { return .formula }
        return .plain
    }

    /// Auto-detect kind for paste-time wrapping. Conservative — only wraps when there are
    /// strong signals (called by `BubbleModel.wrapForDetectedKind`).
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

    private static func isLikelyCode(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains("\n") { return true }
        if trimmed.contains(";") { return true }
        if trimmed.contains("=>") { return true }
        if trimmed.contains("->") { return true }
        if trimmed.contains("<-") { return true }
        let kw = ["function ", "def ", "class ", "import ", "return ",
                  "let ", "var ", "const ", "if (", "if(", "for (", "for(", "while (", "while(",
                  "struct ", "enum ", "protocol ", "guard ", "switch ", "case "]
        for k in kw where trimmed.contains(k) { return true }
        let braces = trimmed.contains("{") || trimmed.contains("}")
        let parens = trimmed.contains("(") && trimmed.contains(")")
        if braces, parens { return true }
        return false
    }

    private static func isLikelyFormula(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if trimmed.contains("\\frac") || trimmed.contains("\\sum") || trimmed.contains("\\int") { return true }
        if trimmed.contains("\\sqrt") || trimmed.contains("\\alpha") || trimmed.contains("\\beta") { return true }
        let opCount = trimmed.filter { "=+−-±×÷⋅∙/^≤≥≠≈∞∑∫∂".contains($0) }.count
        if opCount >= 2, trimmed.count <= 80 { return true }
        return false
    }

    private static func fontSize(forEmoji text: String) -> CGFloat {
        let n = max(1, text.count)
        if n <= 2 { return 96 }
        if n <= 6 { return 72 }
        if n <= 14 { return 52 }
        return 36
    }
}

// MARK: - LaTeX formula view (unchanged)

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

private extension Double {
    func clamped(_ lo: Double, _ hi: Double) -> Double {
        Swift.max(lo, Swift.min(hi, self))
    }
}
