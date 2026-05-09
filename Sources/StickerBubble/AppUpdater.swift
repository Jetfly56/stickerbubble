import AppKit
import Foundation

@MainActor
final class AppUpdater {
    static let currentVersion = "1.0.2"

    private static let apiURL = URL(
        string: "https://api.github.com/repos/Jetfly56/stickerbubble/releases/latest"
    )!

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: String
        }
    }

    func checkForUpdates(silent: Bool = false) {
        Task {
            do {
                let release = try await fetchLatestRelease()
                let tag = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                if isNewer(tag, than: Self.currentVersion) {
                    guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                        if !silent { showAlert("Update \(tag) is available but no download was found.") }
                        return
                    }
                    offerInstall(version: tag, downloadURL: asset.browserDownloadUrl)
                } else if !silent {
                    showAlert("StickerBubble \(Self.currentVersion) is up to date.")
                }
            } catch {
                if !silent {
                    showAlert("Update check failed: \(error.localizedDescription)", style: .warning)
                }
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        var req = URLRequest(url: Self.apiURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, _) = try await URLSession.shared.data(for: req)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Release.self, from: data)
    }

    private func offerInstall(version: String, downloadURL: String) {
        let a = NSAlert()
        a.messageText = "StickerBubble \(version) Available"
        a.informativeText = "You have version \(Self.currentVersion). Install update and relaunch?"
        a.addButton(withTitle: "Install Update")
        a.addButton(withTitle: "Later")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        downloadAndInstall(from: downloadURL)
    }

    private func downloadAndInstall(from urlString: String) {
        guard let url = URL(string: urlString) else { return }
        let progressWindow = makeProgressWindow()
        progressWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Task {
            do {
                let (tempURL, _) = try await URLSession.shared.download(from: url)
                let zipDest = FileManager.default.temporaryDirectory
                    .appendingPathComponent("StickerBubble-update.zip")
                try? FileManager.default.removeItem(at: zipDest)
                try FileManager.default.moveItem(at: tempURL, to: zipDest)
                progressWindow.close()
                try installAndRelaunch(zipURL: zipDest)
            } catch is CancellationError {
                progressWindow.close()
            } catch {
                progressWindow.close()
                showAlert("Update failed: \(error.localizedDescription)", style: .critical)
            }
        }
    }

    private func makeProgressWindow() -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 72),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        w.title = "StickerBubble Update"
        w.level = .modalPanel
        w.isReleasedWhenClosed = false
        w.center()
        let cv = w.contentView!
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 20, width: 32, height: 32))
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        cv.addSubview(spinner)
        let label = NSTextField(labelWithString: "Downloading update…")
        label.frame = NSRect(x: 64, y: 27, width: 216, height: 18)
        label.font = .systemFont(ofSize: 13)
        cv.addSubview(label)
        return w
    }

    private func installAndRelaunch(zipURL: URL) throws {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            showAlert("Cannot install: not running from a .app bundle.", style: .warning)
            return
        }

        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StickerBubble-update-extracted")
        try? FileManager.default.removeItem(at: extractDir)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)

        // Strip quarantine from the zip before extracting so it doesn't propagate to contents.
        let stripZip = Process()
        stripZip.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        stripZip.arguments = ["-cr", zipURL.path]
        try stripZip.run()
        stripZip.waitUntilExit()

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipURL.path, "-d", extractDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.extractFailed }

        let contents = try FileManager.default.contentsOfDirectory(
            at: extractDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )
        guard let newAppURL = contents.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppFound
        }

        let installPath = bundleURL.path
        let newAppPath = newAppURL.path
        let cleanupPath = extractDir.path
        let tmp = FileManager.default.temporaryDirectory

        // Separate copy script so osascript admin escalation needs no path escaping.
        let copyScriptURL = tmp.appendingPathComponent("stickerbubble-copy.sh")
        let copyScript = """
        #!/bin/bash
        rm -rf '\(installPath)'
        cp -R '\(newAppPath)' '\(installPath)'
        /usr/bin/xattr -cr '\(installPath)'
        """
        try copyScript.write(to: copyScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copyScriptURL.path)

        let script = """
        #!/bin/bash
        sleep 1
        /usr/bin/xattr -cr '\(newAppPath)'
        /bin/bash '\(copyScriptURL.path)'
        if [ $? -ne 0 ]; then
            /usr/bin/osascript -e 'do shell script "/bin/bash \(copyScriptURL.path)" with administrator privileges'
        fi
        /usr/bin/open '\(installPath)'
        rm -rf '\(cleanupPath)'
        """

        let scriptURL = tmp.appendingPathComponent("stickerbubble-install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [scriptURL.path]
        try proc.run()

        NSApp.terminate(nil)
    }

    @discardableResult
    private func showAlert(_ message: String, style: NSAlert.Style = .informational) -> NSApplication.ModalResponse {
        let a = NSAlert()
        a.messageText = message
        a.alertStyle = style
        return a.runModal()
    }

    private func isNewer(_ candidate: String, than current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    enum UpdateError: LocalizedError {
        case extractFailed
        case noAppFound

        var errorDescription: String? {
            switch self {
            case .extractFailed: "Failed to extract the update archive."
            case .noAppFound: "No .app bundle found in the update archive."
            }
        }
    }
}
