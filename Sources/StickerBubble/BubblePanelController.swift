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
        panel.hasShadow = true
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
        model.onSendSuccess = { [weak self] in
            self?.hide()
        }
        model.onNewInboxFromBackgroundPoll = { [weak self] in
            self?.show()
        }

        hostingView.frame = contentRect
        centerPanel()

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Only handle keys we care about; everything else goes through unchanged (including ⌘V for Edit → paste:).
            if event.keyCode == 53 {
                self.hide()
                return nil
            }
            if event.modifierFlags.contains(.command),
               event.modifierFlags.contains(.shift),
               event.charactersIgnoringModifiers?.lowercased() == "v"
            {
                self.model.loadFromPasteboard()
                return nil
            }
            return event
        }

        installWindowDragMonitors()
    }

    func teardown() {
        model.stopRailwayPoll()
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        removeWindowDragMonitors()
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
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
        let width = max(360, min(560, fitting.width))
        let height = max(260, min(vf.height * 0.93, fitting.height))
        var frame = panel.frame
        let deltaY = frame.height - height
        frame.size = NSSize(width: width, height: height)
        frame.origin.y += deltaY
        panel.setFrame(clampedFrame(frame, to: vf), display: true)
    }

    private func clampedFrame(_ frame: NSRect, to vf: NSRect) -> NSRect {
        var f = frame
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

            self.panel.setFrameOrigin(NSPoint(x: originAnchor.x + dx, y: originAnchor.y + dy))
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

    private func hitViewInPanelContent(for event: NSEvent) -> NSView? {
        guard let content = panel.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return content.hitTest(p)
    }

    /// Walks the hit view chain; skips window drag when the user is on a text field, button, or other control.
    /// `NSImageView` subclasses `NSControl` on macOS — it must be allowed **before** the `NSControl` check or sticker drags never start.
    private func shouldAllowWindowDrag(from view: NSView?) -> Bool {
        var current: NSView? = view
        while let v = current {
            if v is NSTextView { return false }
            if v is NSImageView { return true }
            if v is NSControl { return false }
            current = v.superview
        }
        return true
    }
}
