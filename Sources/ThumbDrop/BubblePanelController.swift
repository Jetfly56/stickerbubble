import AppKit
import Combine
import SwiftUI

/// Standard `NSPanel` returns `false` from `canBecomeKey`, so embedded controls (e.g. `TextField`) never get keyboard focus.
private final class KeyableFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class BubblePanelController: NSObject {
    let model: BubbleModel
    private let hostingView: NSHostingView<ChatBubbleView>
    private let panel: NSPanel
    private var keyDownMonitor: Any?
    private var mouseDownMonitor: Any?
    private var mouseDraggedMonitor: Any?
    private var mouseUpMonitor: Any?
    private var cancellables = Set<AnyCancellable>()
    private var isClampingFrameChange = false

    /// Screen-space anchor when a drag that may move the window began.
    private var windowDragScreenAnchor: NSPoint?
    /// Panel `frame.origin` at mouse-down when drag is allowed.
    private var windowDragOriginAnchor: NSPoint?
    private var windowDragAllowedFromHit: Bool = false
    private var windowDragMovedPastSlop: Bool = false

    override init() {
        model = BubbleModel()

        weak var weakSelf: BubblePanelController?
        let rootView = ChatBubbleView(model: model) {
            weakSelf?.hide()
        }

        hostingView = NSHostingView(rootView: rootView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let contentRect = NSRect(x: 0, y: 0, width: 380, height: 520)
        panel = KeyableFloatingPanel(
            contentRect: contentRect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()
        weakSelf = self

        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Custom drag (see mouse monitors) so stickers, chrome, and recipient chrome move the window;
        // leave false to avoid fighting with programmatic origin updates.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = hostingView

        model.onStickerChanged = { [weak self] in
            self?.resizePanelToFitContent()
        }

        model.$isReceivingMode
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.resizePanelToFitContent()
                }
            }
            .store(in: &cancellables)

        model.$stickerExpanded
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self?.resizePanelToFitContent()
                }
            }
            .store(in: &cancellables)

        model.onSendInitiated = { [weak self] in
            self?.hide()
        }
        model.onSendFailed = { [weak self] in
            self?.show()
        }
        model.onNewInboxFromBackgroundPoll = { [weak self] in
            self?.show()
        }

        hostingView.frame = contentRect
        centerPanel()

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.hide()
                return nil
            }

            let chars = event.charactersIgnoringModifiers?.lowercased()
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let cmdOnly = mods == .command
            let cmdShift = mods == [.command, .shift]

            if cmdShift, chars == "v" {
                self.model.loadFromPasteboard()
                return nil
            }

            if cmdOnly, event.keyCode == 36 {
                Task { await self.model.performSend() }
                return nil
            }

            if cmdOnly {
                switch chars {
                case "c":
                    // Don't override Cmd+C while the text field is focused — let it copy the field's text.
                    if !self.isTextEditorFocused, self.model.stickerSource != nil {
                        self.model.copyCurrentStickerToPasteboard()
                        return nil
                    }
                case "s":
                    Task { await self.model.saveCurrentStickerToSourceFolder() }
                    return nil
                case "f":
                    self.model.stickerExpanded.toggle()
                    return nil
                default:
                    break
                }
            }
            return event
        }

        installWindowDragMonitors()

        NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.isReceivingMode = true }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.model.isReceivingMode = false }
            .store(in: &cancellables)


        NotificationCenter.default.publisher(for: NSWindow.didResizeNotification, object: panel)
            .merge(with: NotificationCenter.default.publisher(for: NSWindow.didMoveNotification, object: panel))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.clampPanelIfNeeded() }
            .store(in: &cancellables)
    }

    func teardown() {
        model.stopMatrixPoll()
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        removeWindowDragMonitors()
    }

    func show() {
        model.isReceivingMode = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let screen = self.panel.screen ?? NSScreen.main else { return }
            let vf = screen.visibleFrame
            self.panel.setFrame(self.clampedFrame(self.panel.frame, to: vf), display: false)
        }
    }

    func hide() {
        panel.orderOut(nil)
    }

    func pasteStickerFromPasteboard() {
        model.loadFromPasteboard()
    }

    /// Screen-space frame of the bubble (for placing Settings above it).
    var bubblePanelFrame: NSRect { panel.frame }

    /// Screen that owns the bubble (for clamping).
    var bubblePanelScreen: NSScreen? { panel.screen }

    private func centerPanel() {
        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2)
        let centered = NSRect(origin: origin, size: size)
        panel.setFrameOrigin(clampedFrame(centered, to: vf).origin)
    }

    private func resizePanelToFitContent() {
        hostingView.invalidateIntrinsicContentSize()
        hostingView.layoutSubtreeIfNeeded()

        let screen = panel.screen ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let fitting = hostingView.fittingSize
        let width = StickerCardLayout.defaultFrameWidth + 36
        let height = max(260, min(vf.height, fitting.height))
        var frame = panel.frame
        let deltaY = frame.height - height
        frame.size = NSSize(width: width, height: height)
        frame.origin.y += deltaY
        panel.setFrame(clampedFrame(frame, to: vf), display: true)
    }

    private func clampPanelIfNeeded() {
        guard !isClampingFrameChange else { return }
        let screen = panel.screen ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let clamped = clampedFrame(panel.frame, to: vf)
        guard clamped != panel.frame else { return }
        isClampingFrameChange = true
        panel.setFrame(clamped, display: false)
        isClampingFrameChange = false
    }

    private func clampedFrame(_ frame: NSRect, to vf: NSRect) -> NSRect {
        var f = frame
        // Cap size to visible frame before adjusting origin
        f.size.width = min(f.size.width, vf.width)
        f.size.height = min(f.size.height, vf.height)
        // Horizontal
        f.origin.x = max(vf.minX, min(f.origin.x, vf.maxX - f.width))
        // Vertical: push up if bottom clips, then push down if top still clips
        if f.origin.y < vf.minY { f.origin.y = vf.minY }
        if f.origin.y + f.height > vf.maxY { f.origin.y = vf.maxY - f.height }
        return f
    }

    // MARK: - Drag to move window (any non-control surface)

    private func installWindowDragMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            if self.model.receivedFromName != nil { self.model.receivedFromName = nil }
            self.resetWindowDragState()
            let hit = self.hitViewInPanelContent(for: event)
            self.windowDragAllowedFromHit = self.shouldAllowWindowDrag(from: hit)
            guard self.windowDragAllowedFromHit else { return event }
            self.windowDragScreenAnchor = NSEvent.mouseLocation
            self.windowDragOriginAnchor = self.panel.frame.origin
            return event
        }

        mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            guard self.windowDragAllowedFromHit,
                  let screenAnchor = self.windowDragScreenAnchor,
                  let originAnchor = self.windowDragOriginAnchor
            else {
                return event
            }

            let now = NSEvent.mouseLocation
            let dx = now.x - screenAnchor.x
            let dy = now.y - screenAnchor.y

            if !self.windowDragMovedPastSlop {
                if hypot(dx, dy) < 5 {
                    return event
                }
                self.windowDragMovedPastSlop = true
            }

            let newOrigin = NSPoint(x: originAnchor.x + dx, y: originAnchor.y + dy)
            let screen = self.panel.screen ?? NSScreen.main
            if let vf = screen?.visibleFrame {
                let proposed = NSRect(origin: newOrigin, size: self.panel.frame.size)
                self.panel.setFrameOrigin(self.clampedFrame(proposed, to: vf).origin)
            } else {
                self.panel.setFrameOrigin(newOrigin)
            }
            return event
        }

        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel {
                self.resetWindowDragState()
            }
            return event
        }
    }

    private func removeWindowDragMonitors() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        if let mouseDraggedMonitor {
            NSEvent.removeMonitor(mouseDraggedMonitor)
            self.mouseDraggedMonitor = nil
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
        resetWindowDragState()
    }

    private func resetWindowDragState() {
        windowDragScreenAnchor = nil
        windowDragOriginAnchor = nil
        windowDragAllowedFromHit = false
        windowDragMovedPastSlop = false
    }

    private var isTextEditorFocused: Bool {
        panel.firstResponder is NSText
    }

    private func hitViewInPanelContent(for event: NSEvent) -> NSView? {
        guard let content = panel.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return content.hitTest(p)
    }

    /// Walks the hit view chain; skips window drag when the user is on a text field, button, or other control.
    private func shouldAllowWindowDrag(from view: NSView?) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSTextView { return false }
            // The sticker canvas owns its own pan/zoom interaction. When it's active
            // (image is pannable or in edit mode) we deny window drag so the canvas's
            // mouse handlers run cleanly. When inactive (small image, fit-mode) we allow
            // window drag so the bubble keeps acting as a draggable surface.
            if let canvas = v as? StickerCanvasNSView {
                return !canvas.isInteractive
            }
            if v is NSControl { return false }
            current = v.superview
        }

        // Geometric fallback: SwiftUI sometimes interposes a hosting view between the
        // panel content and our canvas, so the responder-chain walk above doesn't
        // resolve to a `StickerCanvasNSView`. Scan for any interactive canvas in the
        // panel and check whether the click point is inside its frame in window
        // coordinates — defends against the "drag bleeds when image is at the edge of
        // its pan range" failure mode where the cursor sits over a SwiftUI view above
        // the canvas.
        if let content = panel.contentView, let event = NSApp.currentEvent {
            let inWindow = event.locationInWindow
            if anyInteractiveCanvasContains(windowPoint: inWindow, root: content) {
                return false
            }
        }

        return true
    }

    private func anyInteractiveCanvasContains(windowPoint: NSPoint, root: NSView) -> Bool {
        if let canvas = root as? StickerCanvasNSView, canvas.isInteractive {
            let local = canvas.convert(windowPoint, from: nil)
            if canvas.bounds.contains(local) { return true }
        }
        for sub in root.subviews {
            if anyInteractiveCanvasContains(windowPoint: windowPoint, root: sub) { return true }
        }
        return false
    }
}
