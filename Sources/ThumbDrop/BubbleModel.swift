import AppKit
import Combine
import Foundation

@MainActor
final class BubbleModel: ObservableObject {
    private static let folderBookmarkKey = "ThumbDrop.sourceFolderBookmark"
    private static let folderPathKey = "ThumbDrop.sourceFolderPath"
    private static let globallyMutedKey = "ThumbDrop.globallyMuted"
    private static let lastSelectedPeerKeyPrefix = "ThumbDrop.lastSelectedPeer"
    private static let matrixHomeserverURLKey = "ThumbDrop.matrix.homeserverURL"
    private static let matrixUserIdKey = "ThumbDrop.matrix.userId"
    private static let matrixAccessTokenKey = "ThumbDrop.matrix.accessToken"
    private static let matrixDeviceIdKey = "ThumbDrop.matrix.deviceId"
    private static let matrixContactsKeyPrefix = "ThumbDrop.matrix.contacts"
    private static let favoritePeerMxidsKeyPrefix = "ThumbDrop.favoritePeerMxids"
    private static let mutedPeerMxidsKeyPrefix = "ThumbDrop.mutedPeerMxids"

    /// Per-account ordered list of peer MXIDs shown as quick-pick chips on the bubble (local only).
    @Published private(set) var favoritePeerMxidsOrdered: [String] = []

    /// Per-account set of peer MXIDs whose incoming messages don't pop the bubble (local only).
    @Published private(set) var mutedPeerMxids: Set<String> = []

    /// Who this draft preview is for (shown on the bubble — not sent anywhere).
    @Published var recipientName: String = ""
    @Published var recipientDetail: String = ""

    @Published var stickerSource: StickerSource? {
        didSet {
            switch stickerSource {
            case .url, .image, nil: stickerExpanded = false
            case .text: break
            }
            stickerTransform.reset()
            stickerTransformNonce &+= 1
        }
    }
    @Published var stickerExpanded: Bool = false
    /// Pan offset + zoom held outside `@Published` so gesture updates don't re-render the
    /// rest of the bubble. `StickerDisplay` mutates this directly; the model reads at
    /// send time and writes when applying received messages.
    let stickerTransform = StickerTransformHolder()

    /// Text field for typing emoji / short messages before Send.
    @Published var emojiField: String = "" {
        didSet {
            if skipEmojiFieldStickerSync { return }
            if case .text(let existing) = stickerSource,
               existing.contains("```") || existing.contains("$$")
            {
                return
            }
            let trimmed = emojiField.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                if case .text = stickerSource {
                    stickerSource = nil
                    onStickerChanged?()
                }
            } else {
                stickerSource = .text(trimmed)
                onStickerChanged?()
            }
        }
    }

    private var skipEmojiFieldStickerSync = false

    func setStickerTextAndClearField(_ text: String) {
        skipEmojiFieldStickerSync = true
        emojiField = ""
        skipEmojiFieldStickerSync = false
        stickerSource = .text(text)
        onStickerChanged?()
    }

    func unwrapStickerToField(_ text: String) {
        skipEmojiFieldStickerSync = true
        emojiField = text
        skipEmojiFieldStickerSync = false
        stickerSource = .text(text)
        onStickerChanged?()
    }

    @Published private(set) var sourceFolderURL: URL?
    @Published private(set) var folderImageURLs: [URL] = []

    private var isAccessingSourceFolder = false

    @Published var receivedFromName: String?
    @Published var isReceivingMode: Bool = false
    /// When true, the bubble shows only the sticker area + a Done button. The chrome
    /// (Send to picker, emoji field, send button, error pills) is hidden so SwiftUI
    /// has nothing else to re-render while the user adjusts pan/zoom.
    @Published var isEditingTransform: Bool = false
    /// Bumped whenever `stickerTransform` is overwritten by code outside `StickerDisplay`
    /// (e.g. an inbox message being loaded into the bubble, or a zoom-button click). The
    /// view watches this nonce to know when to re-sync the canvas from the holder.
    @Published private(set) var stickerTransformNonce: Int = 0

    /// Called by the StickerDisplay zoom buttons after they write new pan/scale to the
    /// holder. The bump triggers `StickerCanvasView.updateNSView` which re-applies the
    /// transform on the canvas.
    func bumpStickerTransformNonce() {
        stickerTransformNonce &+= 1
    }

    var onStickerChanged: (() -> Void)?
    /// Fired right after Send validation passes, before the network call. Used to close
    /// the bubble optimistically so the user gets instant feedback.
    var onSendInitiated: (() -> Void)?
    /// Fired if the actual upload/send fails after the bubble was closed optimistically.
    /// Used to re-open the bubble so the error becomes visible.
    var onSendFailed: (() -> Void)?
    /// Invoked when /sync sees new message(s) after the warmup pass (so launch / sign-in doesn't pop the bubble).
    var onNewInboxFromBackgroundPoll: (() -> Void)?

    @Published var lastError: String?

    @Published var globallyMuted: Bool = UserDefaults.standard.bool(forKey: BubbleModel.globallyMutedKey) {
        didSet { UserDefaults.standard.set(globallyMuted, forKey: Self.globallyMutedKey) }
    }

    // MARK: - Matrix

    @Published var matrixHomeserverURL: String = UserDefaults.standard.string(forKey: BubbleModel.matrixHomeserverURLKey)
        ?? MatrixClient.defaultHomeserverURL
    @Published var matrixUserId: String = UserDefaults.standard.string(forKey: BubbleModel.matrixUserIdKey) ?? ""
    @Published var matrixAccessToken: String = UserDefaults.standard.string(forKey: BubbleModel.matrixAccessTokenKey) ?? ""
    @Published var matrixDeviceId: String = UserDefaults.standard.string(forKey: BubbleModel.matrixDeviceIdKey) ?? ""
    @Published var matrixContacts: [MatrixContact] = []
    @Published var inboxTriageList: [InboxMessage] = []
    /// MXID of the currently selected Matrix contact, used as the send target.
    @Published var selectedPeerMxid: String = "" {
        didSet { saveLastSelectedPeer() }
    }

    private var matrixPollTask: Task<Void, Never>?
    private var matrixSyncSince: String = ""
    private var isMatrixSyncWarmup = true
    /// Tracks which Matrix room each synthetic inbox row came from, so Reply can target the right room.
    private var matrixRoomByInboxId: [Int64: String] = [:]

    var isSignedInToMatrix: Bool {
        !matrixAccessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the bubble is rendering a pan/zoom-capable image. Mirrors
    /// `StickerDisplay.shouldUsePannableView` so window-drag suppression stays in lockstep
    /// with the actual pannable view (otherwise zooming out past the frame size silently
    /// re-enables window-drag from the image).
    var isShowingPannableImage: Bool {
        guard !stickerExpanded else { return false }
        let img: NSImage?
        switch stickerSource {
        case .image(let i): img = i
        case .url(let u):
            if MusicLinkService(url: u) != nil { return false }
            img = NSImage(contentsOf: u)
        case .text, .none: return false
        }
        guard let image = img else { return false }
        let dims = MediaNaturalSize.displaySize(forBitmap: image)
        let natural = MediaNaturalSize.logicalSize(for: image)
        let naturallyOversized = natural.width > dims.width + 0.5 || natural.height > dims.height + 0.5
        if naturallyOversized { return true }
        return stickerTransform.scale > 1.0 + 0.001
    }

    init() {
        restoreSourceFolder()
        loadFavoritePeerMxidsForCurrentAccount()
        loadMutedPeersForCurrentAccount()
        loadLastSelectedPeerForCurrentAccount()
        loadMatrixContacts()
        startMatrixPollIfConfigured()
    }

    // MARK: - Per-account local prefs (favorites, mutes, last-selected peer)

    private static func favoritePeerMxidsKey(matrixUserId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:@"))
        let slug = String(matrixUserId.unicodeScalars.filter { allowed.contains($0) })
        return "\(favoritePeerMxidsKeyPrefix).\(slug.isEmpty ? "__guest__" : slug)"
    }

    private func loadFavoritePeerMxidsForCurrentAccount() {
        let key = Self.favoritePeerMxidsKey(matrixUserId: matrixUserId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            favoritePeerMxidsOrdered = []
            return
        }
        favoritePeerMxidsOrdered = decoded
    }

    private func saveFavoritePeerMxidsForCurrentAccount() {
        let key = Self.favoritePeerMxidsKey(matrixUserId: matrixUserId)
        guard !matrixUserId.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(favoritePeerMxidsOrdered) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func toggleFavoritePeer(mxid: String) {
        let id = mxid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var next = favoritePeerMxidsOrdered
        if let idx = next.firstIndex(of: id) {
            next.remove(at: idx)
        } else {
            next.append(id)
        }
        favoritePeerMxidsOrdered = next
        saveFavoritePeerMxidsForCurrentAccount()
    }

    func isFavoritePeer(_ mxid: String) -> Bool {
        favoritePeerMxidsOrdered.contains(mxid)
    }

    /// Favorite contacts in saved order (must exist in `matrixContacts`).
    func favoriteContactsForBubbleBar() -> [MatrixContact] {
        let byId = Dictionary(uniqueKeysWithValues: matrixContacts.map { ($0.peerMxid, $0) })
        return favoritePeerMxidsOrdered.compactMap { byId[$0] }
    }

    private func pruneFavoritePeersAgainstContacts() {
        guard !favoritePeerMxidsOrdered.isEmpty else { return }
        let valid = Set(matrixContacts.map(\.peerMxid))
        let filtered = favoritePeerMxidsOrdered.filter { valid.contains($0) }
        guard filtered.count != favoritePeerMxidsOrdered.count else { return }
        favoritePeerMxidsOrdered = filtered
        saveFavoritePeerMxidsForCurrentAccount()
    }

    private static func mutedPeerMxidsKey(matrixUserId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:@"))
        let slug = String(matrixUserId.unicodeScalars.filter { allowed.contains($0) })
        return "\(mutedPeerMxidsKeyPrefix).\(slug.isEmpty ? "__guest__" : slug)"
    }

    private func loadMutedPeersForCurrentAccount() {
        let key = Self.mutedPeerMxidsKey(matrixUserId: matrixUserId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            mutedPeerMxids = []
            return
        }
        mutedPeerMxids = Set(decoded)
    }

    private func saveMutedPeersForCurrentAccount() {
        let key = Self.mutedPeerMxidsKey(matrixUserId: matrixUserId)
        guard !matrixUserId.isEmpty else { return }
        guard let data = try? JSONEncoder().encode(Array(mutedPeerMxids)) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func toggleMutePeer(_ mxid: String) {
        let id = mxid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        if mutedPeerMxids.contains(id) {
            mutedPeerMxids.remove(id)
        } else {
            mutedPeerMxids.insert(id)
        }
        saveMutedPeersForCurrentAccount()
    }

    func isPeerMuted(_ mxid: String) -> Bool {
        mutedPeerMxids.contains(mxid)
    }

    private static func lastSelectedPeerKey(matrixUserId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:@"))
        let slug = String(matrixUserId.unicodeScalars.filter { allowed.contains($0) })
        return slug.isEmpty ? "\(lastSelectedPeerKeyPrefix).__guest__" : "\(lastSelectedPeerKeyPrefix).\(slug)"
    }

    private func loadLastSelectedPeerForCurrentAccount() {
        let key = Self.lastSelectedPeerKey(matrixUserId: matrixUserId)
        selectedPeerMxid = UserDefaults.standard.string(forKey: key) ?? ""
    }

    private func saveLastSelectedPeer() {
        guard !matrixUserId.isEmpty else { return }
        let key = Self.lastSelectedPeerKey(matrixUserId: matrixUserId)
        UserDefaults.standard.set(selectedPeerMxid, forKey: key)
    }

    // MARK: - Matrix sign-in

    static func isValidMxid(_ raw: String) -> Bool {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("@") else { return false }
        let rest = s.dropFirst()
        guard let colon = rest.firstIndex(of: ":") else { return false }
        let local = rest[..<colon]
        let server = rest[rest.index(after: colon)...]
        return !local.isEmpty && !server.isEmpty && server.contains(".")
    }

    func setMatrixHomeserverURL(_ raw: String) {
        guard let normalized = MatrixClient.normalizeHomeserverURL(raw) else {
            lastError = "Invalid homeserver URL."
            return
        }
        matrixHomeserverURL = normalized
        UserDefaults.standard.set(normalized, forKey: Self.matrixHomeserverURLKey)
    }

    func signInToMatrix(username: String, password: String) async {
        lastError = nil
        guard let homeserver = MatrixClient.normalizeHomeserverURL(matrixHomeserverURL) else {
            lastError = "Set a homeserver URL first."
            return
        }
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty else {
            lastError = "Enter your username (the localpart, without @ or :server)."
            return
        }
        guard !password.isEmpty else {
            lastError = "Enter your password."
            return
        }
        do {
            let res = try await MatrixClient.login(homeserverURL: homeserver, username: user, password: password)
            persistMatrixCreds(userId: res.userId, accessToken: res.accessToken, deviceId: res.deviceId)
            startMatrixPollIfConfigured()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Beeper Desktop sign-in

    /// Reads Beeper Desktop's local `account.db` and signs in directly with the recovered token.
    /// This is the third-party-blessed path (matches `bbctl --desktop-data-dir`).
    func signInToBeeperFromDesktop(_ account: BeeperLocalAuth.Account) async {
        lastError = nil
        let homeserver: String
        if let normalized = MatrixClient.normalizeHomeserverURL(account.homeserver) {
            homeserver = normalized
        } else {
            homeserver = MatrixClient.beeperHomeserverURL
        }
        matrixHomeserverURL = homeserver
        UserDefaults.standard.set(homeserver, forKey: Self.matrixHomeserverURLKey)
        persistMatrixCreds(userId: account.userId, accessToken: account.accessToken, deviceId: account.deviceId)
        startMatrixPollIfConfigured()
    }

    func signInToMatrixWithAccessToken(_ token: String) async {
        lastError = nil
        guard let homeserver = MatrixClient.normalizeHomeserverURL(matrixHomeserverURL) else {
            lastError = "Set a homeserver URL first."
            return
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Paste an access token."
            return
        }
        do {
            let who = try await MatrixClient.whoami(homeserverURL: homeserver, accessToken: trimmed)
            persistMatrixCreds(userId: who.userId, accessToken: trimmed, deviceId: who.deviceId)
            startMatrixPollIfConfigured()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func persistMatrixCreds(userId: String, accessToken: String, deviceId: String) {
        matrixUserId = userId
        matrixAccessToken = accessToken
        matrixDeviceId = deviceId
        UserDefaults.standard.set(matrixHomeserverURL, forKey: Self.matrixHomeserverURLKey)
        UserDefaults.standard.set(userId, forKey: Self.matrixUserIdKey)
        UserDefaults.standard.set(accessToken, forKey: Self.matrixAccessTokenKey)
        UserDefaults.standard.set(deviceId, forKey: Self.matrixDeviceIdKey)
        loadMatrixContacts()
        loadFavoritePeerMxidsForCurrentAccount()
        loadMutedPeersForCurrentAccount()
        loadLastSelectedPeerForCurrentAccount()
    }

    func signOutFromMatrix() {
        let token = matrixAccessToken
        let homeserver = matrixHomeserverURL
        stopMatrixPoll()
        matrixUserId = ""
        matrixAccessToken = ""
        matrixDeviceId = ""
        matrixContacts = []
        favoritePeerMxidsOrdered = []
        mutedPeerMxids = []
        selectedPeerMxid = ""
        inboxTriageList = []
        matrixRoomByInboxId = [:]
        matrixSyncSince = ""
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Self.matrixUserIdKey)
        UserDefaults.standard.removeObject(forKey: Self.matrixAccessTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.matrixDeviceIdKey)
        if !token.isEmpty {
            Task { await MatrixClient.logout(homeserverURL: homeserver, accessToken: token) }
        }
    }

    // MARK: - Matrix contacts

    private static func matrixContactsKey(matrixUserId: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:@"))
        let slug = String(matrixUserId.unicodeScalars.filter { allowed.contains($0) })
        return "\(matrixContactsKeyPrefix).\(slug.isEmpty ? "__guest__" : slug)"
    }

    private func loadMatrixContacts() {
        let key = Self.matrixContactsKey(matrixUserId: matrixUserId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([MatrixContact].self, from: data)
        else {
            matrixContacts = []
            return
        }
        matrixContacts = decoded
    }

    private func saveMatrixContacts() {
        guard !matrixUserId.isEmpty else { return }
        let key = Self.matrixContactsKey(matrixUserId: matrixUserId)
        guard let data = try? JSONEncoder().encode(matrixContacts) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// Add a Matrix peer as a contact. Reuses an existing 1-1 room from `m.direct` when present;
    /// otherwise creates a new private DM room and updates `m.direct`.
    func addMatrixContact(peerMxid rawPeer: String, displayName: String) async {
        lastError = nil
        guard isSignedInToMatrix else {
            lastError = "Sign in to Matrix first."
            return
        }
        let peer = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidMxid(peer) else {
            lastError = "Enter a Matrix ID like @alice:matrix.org"
            return
        }
        if peer == matrixUserId {
            lastError = "That's your own MXID."
            return
        }
        if let existing = matrixContacts.first(where: { $0.peerMxid == peer }) {
            lastError = "Already in your Matrix contacts."
            selectedPeerMxid = existing.peerMxid
            return
        }
        let label = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let labelOrPeer = label.isEmpty ? peer : label

        let homeserver = matrixHomeserverURL
        let token = matrixAccessToken
        let me = matrixUserId

        do {
            let direct = (try? await MatrixClient.getDirectRoomsMap(
                homeserverURL: homeserver,
                accessToken: token,
                userId: me
            )) ?? [:]

            var roomId: String?
            if let candidates = direct[peer] {
                let joined = (try? await MatrixClient.joinedRoomIds(homeserverURL: homeserver, accessToken: token)) ?? []
                let joinedSet = Set(joined)
                roomId = candidates.first(where: { joinedSet.contains($0) })
            }

            if roomId == nil {
                let newRoom = try await MatrixClient.createDirectRoom(
                    homeserverURL: homeserver,
                    accessToken: token,
                    peerMxid: peer
                )
                roomId = newRoom
                var updated = direct
                var rooms = updated[peer] ?? []
                rooms.append(newRoom)
                updated[peer] = rooms
                try? await MatrixClient.setDirectRoomsMap(
                    homeserverURL: homeserver,
                    accessToken: token,
                    userId: me,
                    map: updated
                )
            }

            guard let finalRoomId = roomId else {
                lastError = "Could not resolve a DM room."
                return
            }

            let contact = MatrixContact(peerMxid: peer, displayName: labelOrPeer, roomId: finalRoomId)
            matrixContacts.append(contact)
            saveMatrixContacts()
            selectedPeerMxid = contact.peerMxid
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Creates (or reuses) a "Notes to self" Matrix room and adds it as a contact. Sticker
    /// sends to this contact go to a room that's just you; events from the room — including
    /// ones you sent from other Matrix clients on the same account — appear in the inbox.
    func addSelfMatrixContact() async {
        lastError = nil
        guard isSignedInToMatrix else {
            lastError = "Sign in to Matrix first."
            return
        }
        if let existing = matrixContacts.first(where: { $0.peerMxid == matrixUserId }) {
            selectedPeerMxid = existing.peerMxid
            return
        }
        let homeserver = matrixHomeserverURL
        let token = matrixAccessToken
        let me = matrixUserId
        do {
            // Reuse a self-DM room if one is already recorded in m.direct under our own MXID.
            let direct = (try? await MatrixClient.getDirectRoomsMap(
                homeserverURL: homeserver, accessToken: token, userId: me
            )) ?? [:]
            var roomId: String?
            if let candidates = direct[me] {
                let joined = (try? await MatrixClient.joinedRoomIds(homeserverURL: homeserver, accessToken: token)) ?? []
                let joinedSet = Set(joined)
                roomId = candidates.first(where: { joinedSet.contains($0) })
            }
            if roomId == nil {
                let newRoom = try await MatrixClient.createSelfRoom(homeserverURL: homeserver, accessToken: token)
                roomId = newRoom
                var updated = direct
                var rooms = updated[me] ?? []
                rooms.append(newRoom)
                updated[me] = rooms
                try? await MatrixClient.setDirectRoomsMap(
                    homeserverURL: homeserver, accessToken: token, userId: me, map: updated
                )
            }
            guard let finalRoom = roomId else {
                lastError = "Could not create a self-chat room."
                return
            }
            let contact = MatrixContact(peerMxid: me, displayName: "Me (Notes to self)", roomId: finalRoom)
            matrixContacts.append(contact)
            saveMatrixContacts()
            selectedPeerMxid = me
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteMatrixContact(peerMxid: String) {
        matrixContacts.removeAll { $0.peerMxid == peerMxid }
        saveMatrixContacts()
        if selectedPeerMxid == peerMxid {
            selectedPeerMxid = ""
        }
        pruneFavoritePeersAgainstContacts()
    }

    /// Targets the Matrix conversation that produced `msg` for replies.
    func replyToMatrixInboxMessage(_ msg: InboxMessage) {
        guard msg.id < 0, let roomId = matrixRoomByInboxId[msg.id] else { return }
        if let contact = matrixContacts.first(where: { $0.roomId == roomId }) {
            selectedPeerMxid = contact.peerMxid
        } else {
            // Sender isn't a saved contact yet — surface their MXID as the selection so the
            // user can either reply directly (we'll send into that room) or add them via Settings.
            selectedPeerMxid = msg.senderUserId
        }
    }

    /// Looks up the room id for the currently selected MXID; falls back to looking up by
    /// senderUserId for the case where Reply chose a non-contact sender.
    private func roomIdForSelectedPeer() -> String? {
        if let c = matrixContacts.first(where: { $0.peerMxid == selectedPeerMxid }) {
            return c.roomId
        }
        // Reply-from-non-contact case: find the most recent inbox row from this sender and use its room.
        if let row = inboxTriageList.first(where: { $0.id < 0 && $0.senderUserId == selectedPeerMxid }),
           let room = matrixRoomByInboxId[row.id]
        {
            return room
        }
        return nil
    }

    // MARK: - Send

    private var outboundFilenameForURL: (URL) -> String { { u in
        u.lastPathComponent.isEmpty ? "sticker" : u.lastPathComponent
    } }

    func performSend() async {
        sendEmojiFromInput()

        guard isSignedInToMatrix else {
            lastError = nil
            return
        }
        guard stickerSource != nil else {
            lastError = "Add a sticker or type text in the field, then send."
            return
        }
        guard !selectedPeerMxid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Pick a Matrix contact to send to."
            return
        }
        guard let roomId = roomIdForSelectedPeer() else {
            lastError = "No room for this peer — add them as a Matrix contact in Settings."
            return
        }

        // Close the bubble immediately for instant feedback. The send runs in the background;
        // if it fails, `onSendFailed` re-opens the bubble so the error becomes visible.
        onSendInitiated?()
        await sendCurrentSticker(toRoom: roomId)
    }

    private func sendCurrentSticker(toRoom roomId: String) async {
        guard let source = stickerSource else { return }
        let homeserver = matrixHomeserverURL
        let token = matrixAccessToken
        // Snapshot the holder at send time. The view writes here directly during gestures
        // — no @Published trip — so this is the freshest pan/scale.
        let pan = stickerTransform.panOffset
        let scale = stickerTransform.scale
        do {
            switch source {
            case .text(let t):
                try await MatrixClient.sendText(
                    homeserverURL: homeserver,
                    accessToken: token,
                    roomId: roomId,
                    body: t
                )

            case .image(let img):
                guard let png = pngData(from: img) else {
                    lastError = "Could not encode image."
                    return
                }
                let mxc = try await MatrixClient.uploadMedia(
                    homeserverURL: homeserver,
                    accessToken: token,
                    data: png,
                    contentType: "image/png",
                    filename: "sticker.png"
                )
                var info: [String: Any] = ["mimetype": "image/png", "size": png.count]
                if let dims = Self.pixelDimensions(of: img) {
                    info["w"] = dims.w
                    info["h"] = dims.h
                }
                try await MatrixClient.sendSticker(
                    homeserverURL: homeserver,
                    accessToken: token,
                    roomId: roomId,
                    mxcURL: mxc,
                    info: info,
                    body: "sticker",
                    panOffset: pan,
                    scale: scale
                )

            case .url(let u):
                let bytes: Data
                let contentType: String
                if u.isFileURL {
                    bytes = (try? Data(contentsOf: u)) ?? Data()
                    contentType = Self.guessContentType(forExtension: u.pathExtension)
                } else {
                    let (b, response) = try await URLSession.shared.data(from: u)
                    bytes = b
                    contentType = (response as? HTTPURLResponse)?
                        .value(forHTTPHeaderField: "Content-Type")
                        .flatMap { $0.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } }
                        ?? Self.guessContentType(forExtension: u.pathExtension)
                }
                guard !bytes.isEmpty else {
                    lastError = "Sticker source had no bytes."
                    return
                }
                let filename = outboundFilenameForURL(u)
                let mxc = try await MatrixClient.uploadMedia(
                    homeserverURL: homeserver,
                    accessToken: token,
                    data: bytes,
                    contentType: contentType,
                    filename: filename
                )
                var info: [String: Any] = ["mimetype": contentType, "size": bytes.count]
                if let probe = NSImage(data: bytes), let dims = Self.pixelDimensions(of: probe) {
                    info["w"] = dims.w
                    info["h"] = dims.h
                }
                try await MatrixClient.sendSticker(
                    homeserverURL: homeserver,
                    accessToken: token,
                    roomId: roomId,
                    mxcURL: mxc,
                    info: info,
                    body: filename,
                    panOffset: pan,
                    scale: scale
                )
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            onSendFailed?()
        }
    }

    // MARK: - Inbox

    /// Triggers a one-shot non-blocking sync (sets matrixSyncSince to "" so timeoutMs=0).
    func refreshInboxTriage() async {
        if !isSignedInToMatrix {
            inboxTriageList = []
            return
        }
        // The long-poll already runs; expose a no-op refresh that re-issues a quick sync.
        // (Users hitting Refresh expect to see new things; an immediate non-blocking sync helps.)
        await pollMatrixOnce(homeserver: matrixHomeserverURL, token: matrixAccessToken, me: matrixUserId)
    }

    func loadInboxMessageIntoBubble(_ msg: InboxMessage) {
        applyInboxMessage(msg)
    }

    func deleteInboxMessage(_ msg: InboxMessage) async {
        // Matrix has no "inbox delete" on the server; just drop locally.
        inboxTriageList.removeAll { $0.id == msg.id }
        matrixRoomByInboxId.removeValue(forKey: msg.id)
    }

    func clearInbox() async {
        inboxTriageList = []
        matrixRoomByInboxId = [:]
    }

    private func applyInboxMessage(_ msg: InboxMessage) {
        let senderLabel = msg.senderDisplayName.flatMap { n in
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        } ?? msg.senderUserId
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
        // Apply pan + scale after stickerSource (the didSet on stickerSource resets them).
        var transformChanged = false
        if let s = msg.scale, s > 0 {
            stickerTransform.scale = CGFloat(s)
            transformChanged = true
        }
        if let x = msg.panOffsetX, let y = msg.panOffsetY {
            stickerTransform.panOffset = CGSize(width: x, height: y)
            transformChanged = true
        }
        if transformChanged { stickerTransformNonce &+= 1 }
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

    /// Pixel dimensions across all representations (largest wins). Used for `info.w` / `info.h`
    /// on outbound `m.sticker` events — hungryserv (Beeper) rejects events without them.
    private static func pixelDimensions(of image: NSImage) -> (w: Int, h: Int)? {
        var w = 0
        var h = 0
        for rep in image.representations {
            w = max(w, rep.pixelsWide)
            h = max(h, rep.pixelsHigh)
        }
        if w > 0, h > 0 { return (w, h) }
        // Fall back to the logical size when no bitmap rep is present.
        let s = image.size
        if s.width >= 1, s.height >= 1 {
            return (Int(s.width), Int(s.height))
        }
        return nil
    }

    private static func guessContentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "jpg", "jpeg": return "image/jpeg"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "tiff", "tif": return "image/tiff"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Matrix polling

    func startMatrixPollIfConfigured() {
        stopMatrixPoll()
        isMatrixSyncWarmup = true
        matrixSyncSince = ""
        guard isSignedInToMatrix else { return }
        let token = matrixAccessToken
        let me = matrixUserId
        let homeserver = matrixHomeserverURL
        matrixPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollMatrixOnce(homeserver: homeserver, token: token, me: me)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stopMatrixPoll() {
        matrixPollTask?.cancel()
        matrixPollTask = nil
    }

    private func pollMatrixOnce(homeserver: String, token: String, me: String) async {
        let firstSync = matrixSyncSince.isEmpty
        let timeoutMs = firstSync ? 0 : 30_000
        let selfRoomIds = Set(matrixContacts.filter { $0.peerMxid == me }.map { $0.roomId })
        do {
            let res = try await MatrixClient.sync(
                homeserverURL: homeserver,
                accessToken: token,
                since: firstSync ? nil : matrixSyncSince,
                timeoutMs: timeoutMs,
                ownUserId: me,
                selfRoomIds: selfRoomIds
            )
            matrixSyncSince = res.nextBatch
            let wasWarmup = isMatrixSyncWarmup
            isMatrixSyncWarmup = false

            guard !res.events.isEmpty else { return }

            var converted: [InboxMessage] = []
            for ev in res.events {
                var stickerStr: String?
                if let mxc = ev.mxcURL {
                    if let (data, ct) = try? await MatrixClient.downloadMedia(
                        homeserverURL: homeserver,
                        accessToken: token,
                        mxcURL: mxc
                    ) {
                        let mime = ct?.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "image/png"
                        stickerStr = "data:\(mime);base64,\(data.base64EncodedString())"
                    }
                }
                let inboxId = MatrixClient.stableNegativeId(eventId: ev.eventId)
                matrixRoomByInboxId[inboxId] = ev.roomId
                let labelFromContact = matrixContacts.first(where: { $0.roomId == ev.roomId })?.displayName
                converted.append(InboxMessage(
                    id: inboxId,
                    senderUserId: ev.senderUserId,
                    stickerUrl: stickerStr,
                    body: ev.body,
                    senderDisplayName: labelFromContact,
                    panOffsetX: ev.panOffsetX,
                    panOffsetY: ev.panOffsetY,
                    scale: ev.scale
                ))
            }

            // Merge into the inbox triage list, newest first, dedup by stable id.
            var merged = inboxTriageList
            let existingIds = Set(merged.map { $0.id })
            for row in converted where !existingIds.contains(row.id) {
                merged.insert(row, at: 0)
            }
            inboxTriageList = Array(merged.prefix(200))

            if !wasWarmup, !globallyMuted, let latest = converted.last,
               !isPeerMuted(latest.senderUserId)
            {
                applyInboxMessage(latest)
                receivedFromName = latest.senderDisplayName ?? latest.senderUserId
                isReceivingMode = true
                onNewInboxFromBackgroundPoll?()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    // MARK: - Sticker authoring

    func sendEmojiFromInput() {
        let trimmed = emojiField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stickerSource = .text(trimmed)
        onStickerChanged?()
    }

    func loadSticker(url: URL) {
        stickerSource = .url(url)
        emojiField = ""
        receivedFromName = nil
        onStickerChanged?()
    }

    func loadSticker(image: NSImage) {
        stickerSource = .image(image)
        emojiField = ""
        receivedFromName = nil
        onStickerChanged?()
    }

    func clearSticker() {
        stickerSource = nil
        emojiField = ""
        receivedFromName = nil
        onStickerChanged?()
    }

    func loadSticker(text: String) {
        emojiField = ""
        stickerSource = .text(text)
        receivedFromName = nil
        onStickerChanged?()
    }

    @discardableResult
    func copyCurrentStickerToPasteboard() -> Bool {
        guard let source = stickerSource else { return false }
        let pb = NSPasteboard.general
        pb.clearContents()
        switch source {
        case .text(let s):
            return pb.setString(s, forType: .string)
        case .image(let img):
            if let bitmap = img.representations.first as? NSBitmapImageRep,
               let frames = bitmap.value(forProperty: .frameCount) as? Int, frames > 1,
               let gifData = bitmap.representation(using: .gif, properties: [:])
            {
                return Self.writeGifWithPNGFallback(gifData: gifData, image: img, to: pb)
            }
            return pb.writeObjects([img])
        case .url(let u):
            if let bytes = try? Data(contentsOf: u) {
                if Self.isGifData(bytes) {
                    return Self.writeGifWithPNGFallback(gifData: bytes, image: NSImage(data: bytes), to: pb)
                }
                if let img = NSImage(data: bytes) {
                    return pb.writeObjects([img])
                }
            }
            return pb.writeObjects([u as NSURL])
        }
    }

    private static func isGifData(_ bytes: Data) -> Bool {
        bytes.count >= 4 && bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x38
    }

    private static func writeGifWithPNGFallback(gifData: Data, image: NSImage?, to pb: NSPasteboard) -> Bool {
        let item = NSPasteboardItem()
        item.setData(gifData, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
        if let img = image,
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:])
        {
            item.setData(png, forType: .png)
        }
        return pb.writeObjects([item])
    }

    @discardableResult
    func saveCurrentStickerToSourceFolder() async -> URL? {
        guard let folder = sourceFolderURL else {
            lastError = "Choose a sticker folder first."
            return nil
        }
        guard let source = stickerSource else { return nil }

        do {
            let data: Data
            let baseName: String
            let ext: String
            switch source {
            case .url(let u):
                data = try Data(contentsOf: u)
                if u.isFileURL {
                    baseName = u.deletingPathExtension().lastPathComponent
                    ext = u.pathExtension.isEmpty ? "png" : u.pathExtension
                } else {
                    baseName = "Sticker-\(Self.stickerTimestamp())"
                    ext = u.pathExtension.isEmpty ? "png" : u.pathExtension
                }
            case .image(let img):
                guard let png = pngData(from: img) else {
                    lastError = "Could not encode image."
                    return nil
                }
                data = png
                baseName = "Sticker-\(Self.stickerTimestamp())"
                ext = "png"
            case .text:
                return nil
            }

            if let existing = folderFile(matching: data) {
                lastError = "Already in your sticker folder as \(existing.lastPathComponent)."
                return nil
            }

            let candidate = folder.appendingPathComponent("\(baseName).\(ext)")
            let dest = Self.uniqueDestination(for: candidate)
            try data.write(to: dest)
            refreshFolderListing()
            lastError = nil
            return dest
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    private func folderFile(matching data: Data) -> URL? {
        guard let folder = sourceFolderURL else { return nil }
        let target = data.count
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }

        while let item = enumerator.nextObject() as? URL {
            guard let isFile = try? item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile, isFile else { continue }
            guard let size = try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize, size == target else { continue }
            if let existing = try? Data(contentsOf: item), existing == data {
                return item
            }
        }
        return nil
    }

    private static func stickerTimestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    private static func uniqueDestination(for url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let suffix = ext.isEmpty ? "\(base)-\(counter)" : "\(base)-\(counter).\(ext)"
            let candidate = dir.appendingPathComponent(suffix)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
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
            return
        }
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty
        {
            if let url = URL(string: text),
               let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
               url.host != nil
            {
                loadSticker(url: url)
                return
            }
            loadSticker(text: Self.wrapForDetectedKind(text))
        }
    }

    private static func wrapForDetectedKind(_ text: String) -> String {
        if text.contains("```") || text.contains("$$") { return text }
        switch StickerDisplay.autoDetectKind(text) {
        case .code: return "```\n\(text)\n```"
        case .formula: return "$$\n\(text)\n$$"
        case .plain: return text
        }
    }

    // MARK: - Source folder

    func setSourceFolder(_ url: URL) {
        stopAccessingSourceFolderIfNeeded()
        isAccessingSourceFolder = url.startAccessingSecurityScopedResource()
        sourceFolderURL = url
        persistFolderBookmark(for: url)
        refreshFolderListing()
    }

    func clearSourceFolder() {
        stopAccessingSourceFolderIfNeeded()
        sourceFolderURL = nil
        folderImageURLs = []
        UserDefaults.standard.removeObject(forKey: Self.folderBookmarkKey)
        UserDefaults.standard.removeObject(forKey: Self.folderPathKey)
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

    private func restoreSourceFolder() {
        if let path = UserDefaults.standard.string(forKey: Self.folderPathKey) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                sourceFolderURL = url
                refreshFolderListing()
                return
            }
        }

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
        isAccessingSourceFolder = url.startAccessingSecurityScopedResource()
        sourceFolderURL = url
        UserDefaults.standard.set(url.path, forKey: Self.folderPathKey)
        refreshFolderListing()
    }

    private func persistFolderBookmark(for url: URL) {
        UserDefaults.standard.set(url.path, forKey: Self.folderPathKey)
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

/// Reference container for the bubble's transient pan/zoom values. `StickerDisplay` writes
/// to this in its gesture handlers without going through `@Published` — that way panning
/// and zooming don't trigger re-renders in the rest of the bubble. The model reads it
/// once, at send time, to stamp the values onto outgoing `m.sticker` events.
final class StickerTransformHolder {
    var panOffset: CGSize = .zero
    var scale: CGFloat = 1.0

    func reset() {
        panOffset = .zero
        scale = 1.0
    }
}

struct InboxMessage: Codable, Equatable {
    let id: Int64
    let senderUserId: String
    let stickerUrl: String?
    let body: String?
    let senderDisplayName: String?
    /// Pan offset in display points; non-nil only when the sender included it (large stickers).
    let panOffsetX: Double?
    let panOffsetY: Double?
    /// Zoom factor; non-nil only when the sender deviated from 1.0.
    let scale: Double?

    init(
        id: Int64,
        senderUserId: String,
        stickerUrl: String?,
        body: String?,
        senderDisplayName: String?,
        panOffsetX: Double? = nil,
        panOffsetY: Double? = nil,
        scale: Double? = nil
    ) {
        self.id = id
        self.senderUserId = senderUserId
        self.stickerUrl = stickerUrl
        self.body = body
        self.senderDisplayName = senderDisplayName
        self.panOffsetX = panOffsetX
        self.panOffsetY = panOffsetY
        self.scale = scale
    }
}

struct MatrixContact: Codable, Identifiable, Equatable {
    var id: String { peerMxid }
    let peerMxid: String
    var displayName: String
    let roomId: String
}
