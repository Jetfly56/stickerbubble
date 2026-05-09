import AppKit

@main
enum StickerBubbleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // `.regular` is required for the StickerBubble / Edit menus to appear in the menu bar.
        // `.accessory` hides the Dock item and effectively leaves no way to reach the main menu.
        app.setActivationPolicy(.regular)
        app.run()
    }
}
