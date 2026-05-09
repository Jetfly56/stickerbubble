import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var bubbleController: BubblePanelController?
    private var syncHubWindow: NSWindow?
    private let updater = AppUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        bubbleController = BubblePanelController()
        bubbleController?.show()

        NSApp.mainMenu = buildMainMenu()

        DispatchQueue.main.async { [weak self] in
            guard let self, let bc = self.bubbleController, !bc.model.isSignedIn else { return }
            self.openAccountAndSync()
        }

        updater.checkForUpdates(silent: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        bubbleController?.teardown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func buildMainMenu() -> NSMenu {
        let bar = NSMenu()

        let appPullDown = NSMenuItem()
        appPullDown.title = "StickerBubble"
        appPullDown.submenu = buildAppMenu()
        bar.addItem(appPullDown)

        let editPullDown = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editPullDown.submenu = buildEditMenu()
        bar.addItem(editPullDown)

        return bar
    }

    private func buildAppMenu() -> NSMenu {
        let appMenu = NSMenu()

        appMenu.addItem(withTitle: "Show bubble", action: #selector(showBubble), keyEquivalent: "b")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide bubble", action: #selector(hideBubble), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openAccountAndSync), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        let pasteSticker = NSMenuItem(
            title: "Paste as sticker",
            action: #selector(pasteAsSticker),
            keyEquivalent: "v"
        )
        pasteSticker.keyEquivalentModifierMask = [.command, .shift]
        appMenu.addItem(pasteSticker)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit StickerBubble", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in appMenu.items {
            guard !item.isSeparatorItem, let action = item.action else { continue }
            if action == #selector(NSApplication.terminate(_:)) {
                item.target = NSApp
            } else {
                item.target = self
            }
        }

        return appMenu
    }

    private func buildEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")

        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(undo)
        edit.addItem(redo)
        edit.addItem(.separator())

        edit.addItem(withTitle: "Cut", action: Selector(("cut:")), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: Selector(("copy:")), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: Selector(("paste:")), keyEquivalent: "v")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Select All", action: Selector(("selectAll:")), keyEquivalent: "a")

        for item in edit.items {
            guard !item.isSeparatorItem else { continue }
            item.target = nil
        }

        return edit
    }

    @objc private func showBubble() {
        bubbleController?.show()
    }

    @objc private func hideBubble() {
        bubbleController?.hide()
    }

    @objc private func pasteAsSticker() {
        bubbleController?.pasteStickerFromPasteboard()
    }

    @objc private func checkForUpdates() {
        updater.checkForUpdates(silent: false)
    }

    /// Also invoked from the bubble panel (menu bar is not always the focused app).
    @objc func openAccountAndSync() {
        guard let bc = bubbleController else { return }
        if let w = syncHubWindow, w.isVisible {
            configureSettingsWindowLevelAndPlacement(w, bubbleController: bc)
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let host = NSHostingView(rootView: SyncHubView(model: bc.model))
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Settings"
        w.contentView = host
        w.delegate = self
        w.isReleasedWhenClosed = false
        configureSettingsWindowLevelAndPlacement(w, bubbleController: bc)
        syncHubWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Bubble panel uses `.floating`; Settings must use a higher level so it stacks above the sender.
    private func configureSettingsWindowLevelAndPlacement(_ w: NSWindow, bubbleController bc: BubblePanelController) {
        w.level = .modalPanel
        let bubbleFrame = bc.bubblePanelFrame
        let size = w.frame.size
        let gap: CGFloat = 12
        let margin: CGFloat = 8
        var origin = NSPoint(
            x: bubbleFrame.midX - size.width / 2,
            y: bubbleFrame.maxY + gap
        )
        let screen = bc.bubblePanelScreen ?? w.screen ?? NSScreen.main
        if let vf = screen?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX + margin), vf.maxX - size.width - margin)
            let top = origin.y + size.height
            if top > vf.maxY - margin {
                origin.y = vf.maxY - size.height - margin
            }
            if origin.y < vf.minY + margin {
                origin.y = vf.minY + margin
            }
        }
        w.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === syncHubWindow else { return }
        syncHubWindow = nil
    }
}
