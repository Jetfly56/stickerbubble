import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var bubbleController: BubblePanelController?
    private var syncHubWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        bubbleController = BubblePanelController()
        bubbleController?.show()

        NSApp.mainMenu = buildMainMenu()
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
        appMenu.addItem(withTitle: "Account & sync…", action: #selector(openAccountAndSync), keyEquivalent: "")
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

    @objc private func openAccountAndSync() {
        guard let bc = bubbleController else { return }
        if let w = syncHubWindow, w.isVisible {
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
        w.title = "Account & sync"
        w.contentView = host
        w.delegate = self
        w.isReleasedWhenClosed = false
        w.center()
        syncHubWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === syncHubWindow else { return }
        syncHubWindow = nil
    }
}
