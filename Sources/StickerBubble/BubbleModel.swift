import AppKit
import Combine
import Foundation

@MainActor
final class BubbleModel: ObservableObject {
    private static let folderBookmarkKey = "StickerBubble.sourceFolderBookmark"
    private static let railwayURLKey = "StickerBubble.railwayBaseURL"
    private static let railwayDeviceKey = "StickerBubble.railwayDeviceId"
    private static let localDisplayNameKey = "StickerBubble.localDisplayName"

    /// Who this draft preview is for (shown on the bubble — not sent anywhere).
    @Published var recipientName: String = ""
    /// Optional second line under the recipient name (e.g. context for your draft).
    @Published var recipientDetail: String = ""
    @Published var stickerSource: StickerSource?

    /// Text field for typing emoji / short messages before Send.
    @Published var emojiField: String = ""

    /// User-selected folder for sticker files (images). Persisted via security-scoped bookmark when possible.
    @Published private(set) var sourceFolderURL: URL?
    @Published private(set) var folderImageURLs: [URL] = []

    private var isAccessingSourceFolder = false

    var onStickerChanged: (() -> Void)?

    // MARK: - Railway sync

    @Published var railwayBaseURL: String = UserDefaults.standard.string(forKey: BubbleModel.railwayURLKey) ?? ""
    /// Stable account identity on the server (persisted).
    @Published var deviceId: String
    /// Shown in your UI and sent with each server message so recipients see who it is from.
    @Published var localDisplayName: String = UserDefaults.standard.string(forKey: BubbleModel.localDisplayNameKey) ?? ""
    @Published var remoteContacts: [RailwayRemoteContact] = []
    /// Latest inbox rows for triage UI (does not affect poll cursor).
    @Published var inboxTriageList: [RailwayInboxMessage] = []
    /// `peer_device_id` to send server messages to; empty string = not set.
    @Published var selectedPeerDeviceId: String = ""
    @Published var lastRailwayError: String?
    @Published private(set) var lastInboxMessageId: Int64 = 0

    private var pollTask: Task<Void, Never>?

    init() {
        if let existing = UserDefaults.standard.string(forKey: Self.railwayDeviceKey), !existing.isEmpty {
            deviceId = existing
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Self.railwayDeviceKey)
            deviceId = fresh
        }
        restoreSourceFolder()
    }

    func setRailwayBaseURL(_ raw: String) {
        railwayBaseURL = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(railwayBaseURL, forKey: Self.railwayURLKey)
        lastRailwayError = nil
        startRailwayPollIfConfigured()
    }

    func saveLocalDisplayName() {
        UserDefaults.standard.set(localDisplayName, forKey: Self.localDisplayNameKey)
    }

    /// Letters, numbers, `.`, `_`, `-` only; length 2…64. Used for your device ID and recommended for peers.
    static func normalizedDeviceId(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 64).contains(t.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
    }

    /// Persist a custom device ID. Returns `nil` on success, or a user-visible error string.
    func applyDeviceId(_ raw: String) -> String? {
        guard let normalized = Self.normalizedDeviceId(raw) else {
            return "Device ID must be 2–64 characters: letters, numbers, period, underscore, or hyphen."
        }
        if normalized != deviceId {
            UserDefaults.standard.set(normalized, forKey: Self.railwayDeviceKey)
            deviceId = normalized
            lastInboxMessageId = 0
            inboxTriageList = []
            remoteContacts = []
            startRailwayPollIfConfigured()
        }
        return nil
    }

    /// New random device ID (breaks existing contact links — confirm in UI first).
    func regenerateDeviceId() {
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: Self.railwayDeviceKey)
        deviceId = fresh
        lastInboxMessageId = 0
        inboxTriageList = []
        remoteContacts = []
        startRailwayPollIfConfigured()
    }

    private var outboundSenderDisplayName: String? {
        let s = localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    func refreshInboxTriage() async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        do {
            let rows = try await RailwayClient.fetchInbox(baseURL: base, deviceId: deviceId, afterId: 0)
            inboxTriageList = rows.sorted { $0.id > $1.id }.prefix(200).map { $0 }
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func addRemoteContact(displayName: String, peerDeviceId: String) async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let peer = peerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else {
            lastRailwayError = "Peer device ID is required."
            return
        }
        if Self.normalizedDeviceId(peer) == nil {
            lastRailwayError = "Peer device ID must be 2–64 characters: letters, numbers, period, underscore, or hyphen."
            return
        }
        if name.isEmpty {
            await refreshInboxTriage()
        }
        let resolvedName: String = {
            if !name.isEmpty { return name }
            if let row = inboxTriageList.first(where: { $0.senderDeviceId == peer }),
               let inferred = row.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !inferred.isEmpty
            {
                return inferred
            }
            return peer
        }()
        do {
            try await RailwayClient.upsertContact(
                baseURL: base,
                ownerDeviceId: deviceId,
                peerDeviceId: peer,
                displayName: resolvedName
            )
            await refreshRemoteContacts()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func deleteRemoteContact(id: Int) async {
        guard let base = normalizedRailwayBaseURL() else { return }
        do {
            try await RailwayClient.deleteContact(baseURL: base, ownerDeviceId: deviceId, contactId: id)
            await refreshRemoteContacts()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    /// Loads a server inbox row into the floating bubble (same rules as live poll).
    func loadInboxMessageIntoBubble(_ msg: RailwayInboxMessage) {
        applyInboxMessage(msg)
    }

    func startRailwayPollIfConfigured() {
        stopRailwayPoll()
        guard normalizedRailwayBaseURL() != nil else { return }
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollRailwayInboxOnce()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
    }

    func stopRailwayPoll() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refreshRemoteContacts() async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first (Account & sync… in the menu)."
            return
        }
        do {
            remoteContacts = try await RailwayClient.fetchContacts(baseURL: base, deviceId: deviceId)
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    /// Sends the current sticker (URL, text, or PNG of bitmap) to `selectedPeerDeviceId`.
    func sendCurrentStickerToRailway() async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        let peer = selectedPeerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else {
            lastRailwayError = "Pick a contact (peer device ID)."
            return
        }
        guard let source = stickerSource else {
            lastRailwayError = "Nothing to send."
            return
        }

        do {
            switch source {
            case .url(let u):
                try await RailwayClient.postMessage(
                    baseURL: base,
                    senderDeviceId: deviceId,
                    recipientDeviceId: peer,
                    stickerURL: u.absoluteString,
                    body: nil,
                    mediaBase64: nil,
                    mediaContentType: nil,
                    senderDisplayName: outboundSenderDisplayName
                )
            case .text(let t):
                try await RailwayClient.postMessage(
                    baseURL: base,
                    senderDeviceId: deviceId,
                    recipientDeviceId: peer,
                    stickerURL: nil,
                    body: t,
                    mediaBase64: nil,
                    mediaContentType: nil,
                    senderDisplayName: outboundSenderDisplayName
                )
            case .image(let image):
                guard let data = pngData(from: image) else {
                    lastRailwayError = "Could not encode image."
                    return
                }
                try await RailwayClient.postMessage(
                    baseURL: base,
                    senderDeviceId: deviceId,
                    recipientDeviceId: peer,
                    stickerURL: nil,
                    body: nil,
                    mediaBase64: data.base64EncodedString(),
                    mediaContentType: "image/png",
                    senderDisplayName: outboundSenderDisplayName
                )
            }
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    private func pollRailwayInboxOnce() async {
        guard let base = normalizedRailwayBaseURL() else { return }
        do {
            let rows = try await RailwayClient.fetchInbox(baseURL: base, deviceId: deviceId, afterId: lastInboxMessageId)
            guard let maxId = rows.map(\.id).max(), maxId > lastInboxMessageId else { return }
            let newOnes = rows.filter { $0.id > lastInboxMessageId }.sorted { $0.id < $1.id }
            lastInboxMessageId = maxId
            if let latest = newOnes.last {
                applyInboxMessage(latest)
            }
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    private func applyInboxMessage(_ msg: RailwayInboxMessage) {
        let senderLabel = msg.senderDisplayName.flatMap { n in
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } ?? msg.senderDeviceId
        recipientName = senderLabel

        if let s = msg.stickerUrl, !s.isEmpty {
            if s.hasPrefix("data:"), let img = Self.image(fromDataURL: s) {
                stickerSource = .image(img)
            } else if let u = URL(string: s) {
                stickerSource = .url(u)
            }
        } else if let b = msg.body, !b.isEmpty {
            stickerSource = .text(b)
        }
        onStickerChanged?()
    }

    private static func image(fromDataURL raw: String) -> NSImage? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let encoded = String(raw[raw.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func normalizedRailwayBaseURL() -> String? {
        var s = railwayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return nil }
        return s
    }

    func setSourceFolder(_ url: URL) {
        stopAccessingSourceFolderIfNeeded()
        isAccessingSourceFolder = url.startAccessingSecurityScopedResource()
        sourceFolderURL = url
        persistFolderBookmark(for: url)
        refreshFolderListing()
    }

    /// Clears the saved folder and revokes security scope.
    func clearSourceFolder() {
        stopAccessingSourceFolderIfNeeded()
        sourceFolderURL = nil
        folderImageURLs = []
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
    }

    func refreshFolderListing() {
        guard let root = sourceFolderURL else {
            folderImageURLs = []
            return
        }

        let extensions = Set(["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif"].map { $0.lowercased() })
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            folderImageURLs = []
            return
        }

        var urls: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard let isFile = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            if extensions.contains(item.pathExtension.lowercased()) {
                urls.append(item)
            }
        }

        folderImageURLs = urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func sendEmojiFromInput() {
        let trimmed = emojiField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stickerSource = .text(trimmed)
        emojiField = ""
        onStickerChanged?()
    }

    func loadSticker(url: URL) {
        stickerSource = .url(url)
        onStickerChanged?()
    }

    func loadSticker(image: NSImage) {
        stickerSource = .image(image)
        onStickerChanged?()
    }

    func clearSticker() {
        stickerSource = nil
        onStickerChanged?()
    }

    func loadFromPasteboard() {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
           let first = urls.first
        {
            loadSticker(url: first)
            return
        }
        if let image = NSImage(pasteboard: pb) {
            loadSticker(image: image)
        }
    }

    private func restoreSourceFolder() {
        guard let data = UserDefaults.standard.data(forKey: Self.folderBookmarkKey) else { return }

        var stale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                bookmarkDataIsStale: &stale
            )
        else {
            return
        }

        if stale {
            persistFolderBookmark(for: url)
        }

        isAccessingSourceFolder = url.startAccessingSecurityScopedResource()
        sourceFolderURL = url
        refreshFolderListing()
    }

    private func persistFolderBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: Self.folderBookmarkKey)
        } catch {
            // Non–sandboxed runs may still persist path for next session via bookmark when possible.
        }
    }

    private func stopAccessingSourceFolderIfNeeded() {
        if isAccessingSourceFolder, let url = sourceFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
        isAccessingSourceFolder = false
    }
}

enum StickerSource {
    case url(URL)
    case image(NSImage)
    case text(String)
}
