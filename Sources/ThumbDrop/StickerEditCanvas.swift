import AppKit
import SwiftUI

/// Pure-AppKit canvas for displaying and interactively transforming a sticker image.
///
/// Owns:
/// - The image as a CALayer with `contents = CGImage` (transforms are GPU-side)
/// - Animated-GIF playback (we decode all frames once and swap them on a timer; CALayer
///   `contents` is static so we can't lean on `NSImageView` here)
/// - All input: `mouseDown` / `mouseDragged` / `mouseUp` / `magnify` / `scrollWheel`
///
/// When `isInteractive` is true, none of the mouse overrides call `super`. That stops
/// events from propagating up the responder chain, which means the panel's window-drag
/// monitor sees no draggable surface inside the canvas. Combined with `BubblePanelController`
/// deny-listing this class in `shouldAllowWindowDrag`, this gives us two independent guarantees
/// that the bubble window won't move while the user is panning/zooming the image.
///
/// When `isInteractive` is false (small image that fits at 1×, not in edit mode), all
/// overrides call `super` so the bubble keeps acting as a draggable surface — small static
/// stickers should remain a window-mover the same way they were before this rebuild.
final class StickerCanvasNSView: NSView {
    private let imageLayer = CALayer()

    /// Frames extracted from the source image. Always at least one entry while an image is set.
    private var frames: [CGImage] = []
    /// Per-frame delays for animation. Zero / negative entries are clamped to a minimum so we
    /// never schedule a tight loop on malformed GIFs.
    private var frameDelays: [TimeInterval] = []
    private var currentFrameIdx: Int = 0
    private var animationTimer: Timer?

    /// Reference to the model's transform holder. Pan and scale are written here directly,
    /// bypassing `@Published`, so SwiftUI doesn't re-render the bubble during gestures.
    weak var transformHolder: StickerTransformHolder?

    /// Natural image size in display points (matches `MediaNaturalSize.logicalSize`).
    /// Used for clamping pan against `(naturalSize × scale − bounds)`.
    private(set) var imageNaturalSize: CGSize = .zero

    /// When true, the canvas captures all mouse events without forwarding to `super`. When
    /// false, mouse events pass through (lets the bubble window-drag monitor pick them up).
    var isInteractive: Bool = false

    /// Optional callback for double-click on the canvas. Used to toggle the bubble's
    /// scale-to-fit mode without going through a SwiftUI tap gesture (which sits on the
    /// initial mouseDown to disambiguate, making drags feel laggy at the start).
    var onDoubleClick: (() -> Void)?

    /// Fired when a continuous user interaction ends (mouse-up, pinch ended, scroll
    /// gesture ended). The wrapper bumps the model's transform nonce so any external
    /// observers (e.g. the zoom slider) can resync from the holder. We don't bump per-tick
    /// because that would re-render the bubble at gesture rate.
    var onInteractionEnded: (() -> Void)?

    /// When true, the canvas advances the GIF frame on its timer. Setting this also
    /// pauses/resumes the underlying timer.
    var animates: Bool = true {
        didSet { updateAnimationState() }
    }

    /// Absolute floor for zoom-out (used only when the per-image fit-to-frame scale would
    /// drop below it — for very tall/narrow images). `effectiveMinScale` is what gestures
    /// and the slider actually clamp against.
    static let minScale: CGFloat = 0.05
    static let maxScale: CGFloat = 4.0

    /// Per-image min scale: pinned to the scale at which the image exactly fills the
    /// canvas's frame width, so the user can't zoom out and leave empty bands around the
    /// image. Recomputed on `setImage` and whenever the view's frame changes. Capped at
    /// 1.0 so small images that already fit at native size don't get an artificially-high
    /// minimum.
    private(set) var effectiveMinScale: CGFloat = StickerCanvasNSView.minScale

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recomputeEffectiveMinScale()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        imageLayer.anchorPoint = CGPoint(x: 0, y: 0)
        imageLayer.contentsGravity = .resize
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func removeFromSuperview() {
        animationTimer?.invalidate()
        animationTimer = nil
        super.removeFromSuperview()
    }

    // MARK: - Image assignment & GIF playback

    /// Replaces the current image. Decodes every frame of an animated source up front so
    /// later frame swaps are just `imageLayer.contents = frames[idx]` (no reencoding).
    func setImage(_ image: NSImage, naturalSize: CGSize) {
        animationTimer?.invalidate()
        animationTimer = nil
        frames.removeAll(keepingCapacity: true)
        frameDelays.removeAll(keepingCapacity: true)
        currentFrameIdx = 0

        imageNaturalSize = naturalSize
        imageLayer.bounds = CGRect(origin: .zero, size: naturalSize)
        imageLayer.position = .zero
        recomputeEffectiveMinScale()

        let bitmap = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        if let bitmap, let frameCount = bitmap.value(forProperty: .frameCount) as? Int, frameCount > 1 {
            for idx in 0 ..< frameCount {
                bitmap.setProperty(.currentFrame, withValue: idx)
                if let cg = bitmap.cgImage {
                    frames.append(cg)
                    let raw = (bitmap.value(forProperty: .currentFrameDuration) as? TimeInterval) ?? 0.05
                    frameDelays.append(max(0.02, raw))
                }
            }
        } else if let bitmap, let cg = bitmap.cgImage {
            frames = [cg]
            frameDelays = [0]
        } else {
            // Last-resort path: render the NSImage into a CGImage via TIFF round-trip.
            if let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let cg = rep.cgImage
            {
                frames = [cg]
                frameDelays = [0]
            }
        }

        if let first = frames.first {
            withSilencedActions { imageLayer.contents = first }
        } else {
            withSilencedActions { imageLayer.contents = nil }
        }

        applyHolderTransform()
        updateAnimationState()
    }

    private func updateAnimationState() {
        animationTimer?.invalidate()
        animationTimer = nil
        guard animates, frames.count > 1 else { return }
        scheduleNextFrame()
    }

    private func scheduleNextFrame() {
        let delay = frameDelays[currentFrameIdx]
        animationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.advanceFrame()
        }
    }

    private func advanceFrame() {
        guard !frames.isEmpty else { return }
        currentFrameIdx = (currentFrameIdx + 1) % frames.count
        withSilencedActions { imageLayer.contents = frames[currentFrameIdx] }
        if animates, frames.count > 1 { scheduleNextFrame() }
    }

    // MARK: - Transforms

    /// Pulls pan + scale from the holder and writes the layer transform.
    func applyHolderTransform() {
        let holder = transformHolder
        let pan = holder?.panOffset ?? .zero
        let scale = holder?.scale ?? 1.0
        applyTransform(pan: pan, scale: scale)
    }

    /// Applies a centered, scale-to-fit transform without touching the holder. Used for
    /// the `expanded` toggle so we don't lose the user's chosen pan/scale on toggle-back.
    func applyFitTransform() {
        guard imageNaturalSize.width > 0, imageNaturalSize.height > 0 else { return }
        let fit = min(
            bounds.width / imageNaturalSize.width,
            bounds.height / imageNaturalSize.height
        )
        let renderedW = imageNaturalSize.width * fit
        let renderedH = imageNaturalSize.height * fit
        let centeredPan = CGSize(
            width: (bounds.width - renderedW) / 2,
            height: (bounds.height - renderedH) / 2
        )
        applyTransform(pan: centeredPan, scale: fit)
    }

    private func applyTransform(pan: CGSize, scale: CGFloat) {
        withSilencedActions {
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: pan.width, y: pan.height)
            t = t.scaledBy(x: scale, y: scale)
            imageLayer.setAffineTransform(t)
        }
    }

    private func withSilencedActions(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }

    /// Clamps `pan` against the image's scaled rendered size. `pan ∈ [-(rendered − bounds), 0]`
    /// per axis (and `0` when the image fits the bounds in that axis).
    private func clampedPan(_ pan: CGSize, scale: CGFloat) -> CGSize {
        let renderedW = imageNaturalSize.width * scale
        let renderedH = imageNaturalSize.height * scale
        let maxOffsetX: CGFloat = -max(0, renderedW - bounds.width)
        let maxOffsetY: CGFloat = -max(0, renderedH - bounds.height)
        return CGSize(
            width: max(maxOffsetX, min(0, pan.width)),
            height: max(maxOffsetY, min(0, pan.height))
        )
    }

    /// Applies a new scale, anchored on `anchorPoint` in canvas-local coords. The pan is
    /// adjusted so the image-space point currently under `anchorPoint` stays under it.
    private func applyScale(_ rawScale: CGFloat, anchorIn canvas: CGPoint) {
        guard let holder = transformHolder else { return }
        let oldScale = max(holder.scale, 0.0001)
        let newScale = min(Self.maxScale, max(effectiveMinScale, rawScale))

        let pan = holder.panOffset
        let imageX = (canvas.x - pan.width) / oldScale
        let imageY = (canvas.y - pan.height) / oldScale

        let proposedPan = CGSize(
            width: canvas.x - imageX * newScale,
            height: canvas.y - imageY * newScale
        )
        let clamped = clampedPan(proposedPan, scale: newScale)

        holder.scale = newScale
        holder.panOffset = clamped
        applyTransform(pan: clamped, scale: newScale)
    }

    /// Sets an absolute scale anchored on the view's center. Used by the zoom slider so
    /// the bubble's center stays roughly visually stable as the slider drags.
    func setScale(_ rawScale: CGFloat) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        applyScale(rawScale, anchorIn: center)
    }

    /// Re-derives `effectiveMinScale` based on the current image and frame size. Pinned to
    /// the fit-to-frame ratio so zooming out can't shrink the image smaller than the
    /// viewer; capped at 1.0 so small-but-fits images don't get a minimum > native size.
    private func recomputeEffectiveMinScale() {
        guard imageNaturalSize.width > 0, bounds.width > 0 else { return }
        let fit = bounds.width / imageNaturalSize.width
        effectiveMinScale = min(1.0, max(Self.minScale, fit))
        // If current scale is now below the new floor, snap it back up so we don't render
        // the image inside an under-clamped state.
        if let holder = transformHolder, holder.scale < effectiveMinScale {
            setScale(effectiveMinScale)
        }
    }

    // MARK: - Mouse / gesture handling

    private var dragStartPoint: CGPoint?
    private var panAtDragStart: CGSize = .zero

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Handle double-click directly here so SwiftUI's tap-gesture disambiguation
            // doesn't delay the start of single-click drags.
            onDoubleClick?()
            return
        }
        guard isInteractive, let holder = transformHolder else {
            super.mouseDown(with: event)
            return
        }
        dragStartPoint = convert(event.locationInWindow, from: nil)
        panAtDragStart = holder.panOffset
        // Pause animation while the user is interacting — frame redraws fight the gesture.
        animates = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard isInteractive,
              let holder = transformHolder,
              let start = dragStartPoint
        else {
            super.mouseDragged(with: event)
            return
        }
        let now = convert(event.locationInWindow, from: nil)
        let delta = CGSize(width: now.x - start.x, height: now.y - start.y)
        let proposed = CGSize(
            width: panAtDragStart.width + delta.width,
            height: panAtDragStart.height + delta.height
        )
        let clamped = clampedPan(proposed, scale: holder.scale)
        holder.panOffset = clamped
        applyTransform(pan: clamped, scale: holder.scale)
    }

    override func mouseUp(with event: NSEvent) {
        guard isInteractive else {
            super.mouseUp(with: event)
            return
        }
        dragStartPoint = nil
        onInteractionEnded?()
    }

    override func magnify(with event: NSEvent) {
        guard isInteractive, let holder = transformHolder else {
            super.magnify(with: event)
            return
        }
        animates = false
        let anchor = convert(event.locationInWindow, from: nil)
        applyScale(holder.scale * (1 + event.magnification), anchorIn: anchor)
        if event.phase == .ended || event.phase == .cancelled {
            onInteractionEnded?()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isInteractive, let holder = transformHolder else {
            super.scrollWheel(with: event)
            return
        }
        if event.modifierFlags.contains(.command) {
            // cmd+scroll = zoom centered on the cursor. ScrollingDeltaY is positive when
            // the user scrolls "up" with natural scroll; treat that as zoom in.
            let factor = 1 + event.scrollingDeltaY * 0.01
            let anchor = convert(event.locationInWindow, from: nil)
            applyScale(holder.scale * factor, anchorIn: anchor)
        } else {
            // Plain scroll = pan. Sign tuned for macOS natural scroll (scroll up reveals
            // content below ⇒ pan.y becomes more negative).
            let proposed = CGSize(
                width: holder.panOffset.width + event.scrollingDeltaX,
                height: holder.panOffset.height - event.scrollingDeltaY
            )
            let clamped = clampedPan(proposed, scale: holder.scale)
            holder.panOffset = clamped
            applyTransform(pan: clamped, scale: holder.scale)
        }
        if event.phase == .ended || event.phase == .cancelled || event.momentumPhase == .ended {
            onInteractionEnded?()
        }
    }
}

/// Lightweight controller that lets SwiftUI views (the zoom slider) call into the
/// underlying `StickerCanvasNSView` directly, bypassing `@Published` state. The slider's
/// drag thus updates the canvas's CALayer transform and the holder live, without paying
/// for a full bubble-tree re-render on every tick.
final class StickerCanvasController {
    weak var canvas: StickerCanvasNSView?

    func setScale(_ scale: CGFloat) {
        canvas?.setScale(scale)
    }

    var currentScale: CGFloat {
        canvas?.transformHolder?.scale ?? 1.0
    }
}

/// SwiftUI wrapper for `StickerCanvasNSView`. Keeps the canvas's image / interactivity /
/// animation state in sync with model-driven inputs without re-mounting the NSView.
struct StickerCanvasView: NSViewRepresentable {
    let image: NSImage
    let naturalSize: CGSize
    let frameSize: CGSize
    let transform: StickerTransformHolder
    let nonce: Int
    let isEditing: Bool
    let animates: Bool
    /// When true, the canvas applies a centered scale-to-fit transform instead of reading
    /// the holder. Toggling does not modify the holder's saved pan/scale.
    let expanded: Bool
    /// Called when the user double-clicks the canvas. Used to toggle scale-to-fit mode.
    let onDoubleClick: () -> Void
    /// Called when a continuous user interaction ends (drag/pinch/scroll). Wired to the
    /// model's nonce bump so SwiftUI views observing the nonce — the zoom slider — can
    /// resync from the holder.
    let onInteractionEnded: () -> Void
    /// Reference holder to expose the live `StickerCanvasNSView` to SwiftUI without going
    /// through `@Published`. The slider uses this to drive the canvas at full gesture rate
    /// without re-rendering the entire bubble.
    let controller: StickerCanvasController

    final class Coordinator {
        var loadedImageId: ObjectIdentifier?
        var lastNonce: Int?
        var lastExpanded: Bool?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> StickerCanvasNSView {
        let view = StickerCanvasNSView(frame: NSRect(origin: .zero, size: frameSize))
        view.transformHolder = transform
        controller.canvas = view
        applyAll(to: view, coordinator: context.coordinator, force: true)
        return view
    }

    func updateNSView(_ view: StickerCanvasNSView, context: Context) {
        view.transformHolder = transform
        controller.canvas = view
        applyAll(to: view, coordinator: context.coordinator, force: false)
    }

    private func applyAll(to view: StickerCanvasNSView, coordinator: Coordinator, force: Bool) {
        let id = ObjectIdentifier(image)
        if force || coordinator.loadedImageId != id {
            coordinator.loadedImageId = id
            view.setImage(image, naturalSize: naturalSize)
        }
        // Pan/zoom only fires while the user has explicitly entered edit mode. Outside
        // edit mode (and outside scale-to-fit), the canvas is a passthrough surface — drag
        // moves the bubble window, pinch/scroll do nothing.
        view.isInteractive = !expanded && isEditing
        view.animates = animates
        view.onDoubleClick = onDoubleClick
        view.onInteractionEnded = onInteractionEnded

        let expandedChanged = (coordinator.lastExpanded != expanded)
        coordinator.lastExpanded = expanded

        if expanded {
            if force || expandedChanged {
                view.applyFitTransform()
            }
        } else {
            let nonceChanged = (coordinator.lastNonce != nonce)
            coordinator.lastNonce = nonce
            if force || expandedChanged || nonceChanged {
                view.applyHolderTransform()
            }
        }
    }

    private func isPannable(at scale: CGFloat) -> Bool {
        let renderedW = naturalSize.width * scale
        let renderedH = naturalSize.height * scale
        return renderedW > frameSize.width + 0.5 || renderedH > frameSize.height + 0.5
    }
}
