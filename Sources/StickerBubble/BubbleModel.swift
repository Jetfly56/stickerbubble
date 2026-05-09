import AppKit
import Combine
import Foundation

/// Server profile snippet shown while typing an add-contact user ID.
struct PeerUserIdConfirmation: Equatable {
    let userId: String
    let displayName: String
}

enum AddContactPeerLookupState: Equatable {
    case idle
    case checking
    case matched(PeerUserIdConfirmation)
    case noAccountWithThatId
    case invalidHandle
    case yourself
    case lookupFailed
}

@MainActor
final class BubbleModel: ObservableObject {
    private static let folderBookmarkKey = "StickerBubble.sourceFolderBookmark"
    private static let railwayURLKey = "StickerBubble.railwayBaseURL"

    /// Shipped default API base (persisted on first launch; users can change it in Settings).
    static let bundledDefaultRailwayBaseURL = "https://stickerbubble-production.up.railway.app"
    private static let legacyDeviceKey = "StickerBubble.railwayDeviceId"
    private static let installDeviceTokenKey = "StickerBubble.installDeviceToken"
    private static let authTokenKey = "StickerBubble.authToken"
    private static let signedInUserIdKey = "StickerBubble.signedInUserId"
    private static let localDisplayNameKey = "StickerBubble.localDisplayName"
    private static let sendToSelfEnabledKey = "StickerBubble.sendToSelfEnabled"

    /// Per-account ordered list of peer user IDs shown as quick-pick chips on the bubble (local only).
    @Published private(set) var favoritePeerUserIdsOrdered: [String] = []

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
    /// Invoked when background inbox polling sees new message(s), after the initial “catch up” fetch (so launch / sign-in doesn’t pop the bubble).
    var onNewInboxFromBackgroundPoll: (() -> Void)?

    // MARK: - Server account (user-id + password; multiple devices share one account)

    @Published var railwayBaseURL: String
    /// JWT from last sign-in / register / recover.
    @Published var authToken: String = UserDefaults.standard.string(forKey: BubbleModel.authTokenKey) ?? ""
    /// Signed-in account handle (user-id).
    @Published var signedInUserId: String = UserDefaults.standard.string(forKey: BubbleModel.signedInUserIdKey) ?? ""
    /// Shown in UI and sent with messages; synced to server profile when signed in.
    @Published var localDisplayName: String = UserDefaults.standard.string(forKey: BubbleModel.localDisplayNameKey) ?? ""

    @Published var sendToSelfEnabled: Bool = UserDefaults.standard.bool(forKey: BubbleModel.sendToSelfEnabledKey) {
        didSet { UserDefaults.standard.set(sendToSelfEnabled, forKey: Self.sendToSelfEnabledKey) }
    }
    @Published var remoteContacts: [RailwayRemoteContact] = []
    @Published var incomingContactRequests: [RailwayContactRequestIncoming] = []
    @Published var outgoingContactRequests: [RailwayContactRequestOutgoing] = []
    /// Short-lived hint after sending an invite or linking (Settings + bubble add-contact).
    @Published var contactInviteNotice: String?
    /// Debounced server lookup while typing “their user ID” in add-contact flows.
    @Published private(set) var addContactPeerLookup: AddContactPeerLookupState = .idle
    @Published var inboxTriageList: [RailwayInboxMessage] = []
    /// Peer **user-id** (handle) to send to.
    @Published var selectedPeerUserId: String = ""
    @Published var lastRailwayError: String?
    @Published private(set) var lastInboxMessageId: Int64 = 0

    /// Opaque per-install token; same account can sign in on many Macs with different tokens.
    let installDeviceToken: String

    private var pollTask: Task<Void, Never>?
    /// First inbox fetch after polling starts only syncs IDs / applies latest message — doesn’t reveal the bubble (avoids pop on launch or sign-in).
    private var isInboxPollWarmup = true
    private var addContactPeerLookupTask: Task<Void, Never>?
    private var addContactPeerLookupSeq = 0

    var isSignedIn: Bool {
        !authToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init() {
        let trimmedSaved =
            UserDefaults.standard.string(forKey: Self.railwayURLKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let initialRailwayURL: String
        if trimmedSaved.isEmpty {
            initialRailwayURL = Self.bundledDefaultRailwayBaseURL
            UserDefaults.standard.set(initialRailwayURL, forKey: Self.railwayURLKey)
        } else {
            initialRailwayURL = trimmedSaved
        }
        railwayBaseURL = initialRailwayURL

        if let t = UserDefaults.standard.string(forKey: Self.installDeviceTokenKey),
           !t.isEmpty,
           Self.normalizedInstallToken(t) != nil
        {
            installDeviceToken = t
        } else if let legacy = UserDefaults.standard.string(forKey: Self.legacyDeviceKey),
                  !legacy.isEmpty,
                  Self.normalizedInstallToken(legacy) != nil
        {
            installDeviceToken = legacy
            UserDefaults.standard.set(legacy, forKey: Self.installDeviceTokenKey)
        } else {
            let fresh = UUID().uuidString
            UserDefaults.standard.set(fresh, forKey: Self.installDeviceTokenKey)
            installDeviceToken = fresh
        }
        restoreSourceFolder()
        loadFavoritePeerIdsForCurrentAccount()
        startRailwayPollIfConfigured()
    }

    private static func favoritePeerIdsDefaultsKey(accountUserId: String) -> String {
        let t = accountUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "StickerBubble.favoritePeerIds.__guest__" }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let slug = String(t.unicodeScalars.filter { allowed.contains($0) })
        return "StickerBubble.favoritePeerIds.\(slug)"
    }

    private func loadFavoritePeerIdsForCurrentAccount() {
        let key = Self.favoritePeerIdsDefaultsKey(accountUserId: signedInUserId)
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String].self, from: data)
        else {
            favoritePeerUserIdsOrdered = []
            return
        }
        favoritePeerUserIdsOrdered = decoded
    }

    private func saveFavoritePeerIdsForCurrentAccount() {
        let key = Self.favoritePeerIdsDefaultsKey(accountUserId: signedInUserId)
        guard signedInUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        guard let data = try? JSONEncoder().encode(favoritePeerUserIdsOrdered) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func toggleFavoritePeer(peerUserId: String) {
        let id = peerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        var next = favoritePeerUserIdsOrdered
        if let idx = next.firstIndex(of: id) {
            next.remove(at: idx)
        } else {
            next.append(id)
        }
        favoritePeerUserIdsOrdered = next
        saveFavoritePeerIdsForCurrentAccount()
    }

    func isFavoritePeer(_ peerUserId: String) -> Bool {
        favoritePeerUserIdsOrdered.contains(peerUserId)
    }

    /// Favorite contacts in saved order (must exist in `remoteContacts`).
    func favoriteContactsForBubbleBar() -> [RailwayRemoteContact] {
        let byId = Dictionary(uniqueKeysWithValues: remoteContacts.map { ($0.peerUserId, $0) })
        return favoritePeerUserIdsOrdered.compactMap { byId[$0] }
    }

    private func pruneFavoritePeersAgainstContacts() {
        guard !favoritePeerUserIdsOrdered.isEmpty else { return }
        let valid = Set(remoteContacts.map(\.peerUserId))
        let filtered = favoritePeerUserIdsOrdered.filter { valid.contains($0) }
        guard filtered.count != favoritePeerUserIdsOrdered.count else { return }
        favoritePeerUserIdsOrdered = filtered
        saveFavoritePeerIdsForCurrentAccount()
    }

    func setRailwayBaseURL(_ raw: String) {
        railwayBaseURL = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(railwayBaseURL, forKey: Self.railwayURLKey)
        lastRailwayError = nil
        startRailwayPollIfConfigured()
    }

    /// User-id / peer handle: letters, digits, `.`, `_`, `-`; length 2…64.
    static func normalizedUserId(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2 ... 64).contains(t.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
    }

    /// Install device token (8…128 chars, same charset).
    static func normalizedInstallToken(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8 ... 128).contains(t.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard t.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return t
    }

    private func persistAuth(token: String, userId: String) {
        authToken = token
        signedInUserId = userId
        UserDefaults.standard.set(token, forKey: Self.authTokenKey)
        UserDefaults.standard.set(userId, forKey: Self.signedInUserIdKey)
        loadFavoritePeerIdsForCurrentAccount()
    }

    func signOut() {
        stopRailwayPoll()
        authToken = ""
        signedInUserId = ""
        UserDefaults.standard.removeObject(forKey: Self.authTokenKey)
        UserDefaults.standard.removeObject(forKey: Self.signedInUserIdKey)
        remoteContacts = []
        incomingContactRequests = []
        outgoingContactRequests = []
        contactInviteNotice = nil
        inboxTriageList = []
        selectedPeerUserId = ""
        favoritePeerUserIdsOrdered = []
        lastInboxMessageId = 0
        lastRailwayError = nil
        clearAddContactUserIdLookup()
    }

    /// Cancels in-flight lookup and hides confirmation UI (e.g. after sending invite or closing a sheet).
    func clearAddContactUserIdLookup() {
        addContactPeerLookupTask?.cancel()
        addContactPeerLookupSeq &+= 1
        addContactPeerLookup = .idle
    }

    /// Call from views when the “their user ID” draft changes (debounced network lookup).
    func scheduleAddContactUserIdLookup(draftRaw: String) {
        addContactPeerLookupTask?.cancel()
        let trimmed = draftRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            clearAddContactUserIdLookup()
            return
        }
        guard let norm = Self.normalizedUserId(trimmed) else {
            addContactPeerLookup = .invalidHandle
            return
        }
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else {
            addContactPeerLookup = .idle
            return
        }

        addContactPeerLookupSeq &+= 1
        let seq = addContactPeerLookupSeq
        addContactPeerLookup = .checking
        addContactPeerLookupTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            guard seq == self.addContactPeerLookupSeq else { return }
            guard let still = Self.normalizedUserId(draftRaw.trimmingCharacters(in: .whitespacesAndNewlines)),
                  still == norm
            else {
                return
            }
            do {
                if let profile = try await RailwayClient.fetchPeerPublicProfile(
                    baseURL: base,
                    token: tok,
                    normalizedUserId: norm
                ) {
                    guard seq == self.addContactPeerLookupSeq else { return }
                    guard Self.normalizedUserId(draftRaw.trimmingCharacters(in: .whitespacesAndNewlines)) == norm else {
                        return
                    }
                    let dn = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.addContactPeerLookup = .matched(PeerUserIdConfirmation(userId: profile.userId, displayName: dn))
                } else {
                    guard seq == self.addContactPeerLookupSeq else { return }
                    self.addContactPeerLookup = .noAccountWithThatId
                }
            } catch {
                guard seq == self.addContactPeerLookupSeq else { return }
                self.addContactPeerLookup = .lookupFailed
            }
        }
    }

    func register(userId: String, password: String) async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let uid = Self.normalizedUserId(userId) else {
            lastRailwayError = "User ID must be 2–64 characters: letters, numbers, period, underscore, or hyphen."
            return
        }
        guard password.count >= 8 else {
            lastRailwayError = "Password must be at least 8 characters."
            return
        }
        do {
            let res = try await RailwayClient.register(
                baseURL: base,
                userId: uid,
                password: password,
                displayName: localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines),
                deviceToken: installDeviceToken,
                deviceLabel: ProcessInfo.processInfo.hostName
            )
            persistAuth(token: res.token, userId: res.account.userId)
            if !res.account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                localDisplayName = res.account.displayName
                UserDefaults.standard.set(localDisplayName, forKey: Self.localDisplayNameKey)
            }
            lastInboxMessageId = 0
            await refreshRemoteContacts()
            await refreshContactRequests()
            await refreshInboxTriage()
            lastRailwayError = nil
            startRailwayPollIfConfigured()
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func signIn(userId: String, password: String) async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let uid = Self.normalizedUserId(userId) else {
            lastRailwayError = "Invalid user ID."
            return
        }
        do {
            let res = try await RailwayClient.login(
                baseURL: base,
                userId: uid,
                password: password,
                deviceToken: installDeviceToken,
                deviceLabel: ProcessInfo.processInfo.hostName
            )
            persistAuth(token: res.token, userId: res.account.userId)
            if !res.account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                localDisplayName = res.account.displayName
                UserDefaults.standard.set(localDisplayName, forKey: Self.localDisplayNameKey)
            }
            lastInboxMessageId = 0
            await refreshRemoteContacts()
            await refreshContactRequests()
            await refreshInboxTriage()
            lastRailwayError = nil
            startRailwayPollIfConfigured()
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func recoverAccount(userId: String, code: String, newPassword: String) async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let uid = Self.normalizedUserId(userId) else {
            lastRailwayError = "Invalid user ID."
            return
        }
        guard newPassword.count >= 8 else {
            lastRailwayError = "New password must be at least 8 characters."
            return
        }
        do {
            let res = try await RailwayClient.recover(
                baseURL: base,
                userId: uid,
                code: code.trimmingCharacters(in: .whitespacesAndNewlines),
                newPassword: newPassword,
                deviceToken: installDeviceToken,
                deviceLabel: ProcessInfo.processInfo.hostName
            )
            persistAuth(token: res.token, userId: res.account.userId)
            lastInboxMessageId = 0
            await refreshRemoteContacts()
            await refreshContactRequests()
            await refreshInboxTriage()
            lastRailwayError = nil
            startRailwayPollIfConfigured()
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func changePassword(oldPassword: String, newPassword: String) async {
        guard let base = normalizedRailwayBaseURL(), !authToken.isEmpty else {
            lastRailwayError = "Sign in first."
            return
        }
        guard newPassword.count >= 8 else {
            lastRailwayError = "New password must be at least 8 characters."
            return
        }
        do {
            try await RailwayClient.changePassword(baseURL: base, token: authToken, oldPassword: oldPassword, newPassword: newPassword)
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func createRecoveryCode() async throws -> (code: String, expiresAt: String) {
        guard let base = normalizedRailwayBaseURL(), !authToken.isEmpty else {
            throw RailwayClientError.serverMessage("Sign in first.")
        }
        return try await RailwayClient.createRecoveryCode(baseURL: base, token: authToken)
    }

    func saveLocalDisplayName() {
        UserDefaults.standard.set(localDisplayName, forKey: Self.localDisplayNameKey)
        Task {
            await pushDisplayNameToServerIfPossible()
        }
    }

    private func pushDisplayNameToServerIfPossible() async {
        guard let base = normalizedRailwayBaseURL(), !authToken.isEmpty else { return }
        do {
            let acc = try await RailwayClient.patchDisplayName(
                baseURL: base,
                token: authToken,
                displayName: localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            localDisplayName = acc.displayName
            UserDefaults.standard.set(localDisplayName, forKey: Self.localDisplayNameKey)
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    private var outboundSenderDisplayName: String? {
        let s = localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    private func effectiveAuthToken() -> String? {
        let t = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func refreshInboxTriage() async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let tok = effectiveAuthToken() else {
            lastRailwayError = "Sign in to load inbox."
            return
        }
        do {
            let rows = try await RailwayClient.fetchInbox(baseURL: base, token: tok, afterId: 0)
            inboxTriageList = rows.sorted { $0.id > $1.id }.prefix(200).map { $0 }
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func addRemoteContact(displayName: String, peerUserId: String) async {
        contactInviteNotice = nil
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let tok = effectiveAuthToken() else {
            lastRailwayError = "Sign in to manage contacts."
            return
        }
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let peer = peerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else {
            lastRailwayError = "Peer user ID is required."
            return
        }
        guard let peerNorm = Self.normalizedUserId(peer) else {
            lastRailwayError = "Peer user ID must be 2–64 characters: letters, numbers, period, underscore, or hyphen."
            return
        }
        if name.isEmpty {
            await refreshInboxTriage()
        }
        let resolvedName: String = {
            if !name.isEmpty { return name }
            if let row = inboxTriageList.first(where: { $0.senderUserId == peerNorm }),
               let inferred = row.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines),
               !inferred.isEmpty
            {
                return inferred
            }
            return peerNorm
        }()
        do {
            let result = try await RailwayClient.upsertContact(
                baseURL: base,
                token: tok,
                peerUserId: peerNorm,
                displayName: resolvedName
            )
            await refreshRemoteContacts()
            await refreshContactRequests()
            lastRailwayError = nil
            switch result {
            case .invitePending:
                contactInviteNotice =
                    "Invite sent. They must accept in Settings (or you will, if they invited you first) before you can pick them as a contact."
            case .becameContacts:
                contactInviteNotice = "You’re connected — they’re in your contacts now."
            case .alreadyInContacts:
                contactInviteNotice = "Already in your contacts."
            }
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func refreshContactRequests() async {
        guard let base = normalizedRailwayBaseURL() else {
            incomingContactRequests = []
            outgoingContactRequests = []
            return
        }
        guard let tok = effectiveAuthToken() else {
            incomingContactRequests = []
            outgoingContactRequests = []
            return
        }
        do {
            let pair = try await RailwayClient.fetchContactRequests(baseURL: base, token: tok)
            incomingContactRequests = pair.incoming
            outgoingContactRequests = pair.outgoing
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func acceptIncomingContactRequest(requestId: Int, displayNameForRequester: String) async {
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        contactInviteNotice = nil
        do {
            try await RailwayClient.acceptContactRequest(
                baseURL: base,
                token: tok,
                requestId: requestId,
                displayNameForRequester: displayNameForRequester.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            await refreshRemoteContacts()
            await refreshContactRequests()
            contactInviteNotice = "Contact added — you can send stickers to each other."
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func declineIncomingContactRequest(requestId: Int) async {
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        do {
            try await RailwayClient.declineContactRequest(baseURL: base, token: tok, requestId: requestId)
            await refreshContactRequests()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func cancelOutgoingContactRequest(requestId: Int) async {
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        do {
            try await RailwayClient.cancelOutgoingContactRequest(baseURL: base, token: tok, requestId: requestId)
            await refreshContactRequests()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    private func refreshContactRequestsQuiet() async {
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        do {
            let pair = try await RailwayClient.fetchContactRequests(baseURL: base, token: tok)
            incomingContactRequests = pair.incoming
            outgoingContactRequests = pair.outgoing
        } catch {}
    }

    func deleteRemoteContact(id: Int) async {
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        do {
            try await RailwayClient.deleteContact(baseURL: base, token: tok, contactId: id)
            await refreshRemoteContacts()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    func loadInboxMessageIntoBubble(_ msg: RailwayInboxMessage) {
        applyInboxMessage(msg)
    }

    func startRailwayPollIfConfigured() {
        stopRailwayPoll()
        isInboxPollWarmup = true
        guard normalizedRailwayBaseURL() != nil, effectiveAuthToken() != nil else { return }
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
            lastRailwayError = "Set server URL first (Settings in the menu or person button)."
            return
        }
        guard let tok = effectiveAuthToken() else {
            lastRailwayError = "Sign in to load contacts."
            return
        }
        do {
            remoteContacts = try await RailwayClient.fetchContacts(baseURL: base, token: tok)
            pruneFavoritePeersAgainstContacts()
            lastRailwayError = nil
        } catch {
            lastRailwayError = error.localizedDescription
        }
    }

    /// Applies typed text to the sticker card when present, then sends the current sticker to the chosen contact when signed in.
    func performSend() async {
        sendEmojiFromInput()

        guard isSignedIn else {
            lastRailwayError = nil
            return
        }

        guard stickerSource != nil else {
            lastRailwayError = "Add a sticker or type text in the field, then send."
            return
        }

        let peer = selectedPeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else {
            lastRailwayError = "Choose who to send to (Contacts on the bubble)."
            return
        }

        await sendCurrentStickerToRailway()
    }

    func sendCurrentStickerToRailway() async {
        guard let base = normalizedRailwayBaseURL() else {
            lastRailwayError = "Set server URL first."
            return
        }
        guard let tok = effectiveAuthToken() else {
            lastRailwayError = "Sign in to send."
            return
        }
        let peer = selectedPeerUserId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else {
            lastRailwayError = "Pick a contact (their user ID)."
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
                    token: tok,
                    recipientUserId: peer,
                    stickerURL: u.absoluteString,
                    body: nil,
                    mediaBase64: nil,
                    mediaContentType: nil,
                    senderDisplayName: outboundSenderDisplayName
                )
            case .text(let t):
                try await RailwayClient.postMessage(
                    baseURL: base,
                    token: tok,
                    recipientUserId: peer,
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
                    token: tok,
                    recipientUserId: peer,
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
        guard let base = normalizedRailwayBaseURL(), let tok = effectiveAuthToken() else { return }
        await refreshContactRequestsQuiet()
        do {
            let rows = try await RailwayClient.fetchInbox(baseURL: base, token: tok, afterId: lastInboxMessageId)
            guard let maxId = rows.map(\.id).max(), maxId > lastInboxMessageId else { return }
            let newOnes = rows.filter { $0.id > lastInboxMessageId }.sorted { $0.id < $1.id }
            lastInboxMessageId = maxId
            let skipReveal = isInboxPollWarmup
            isInboxPollWarmup = false
            if !skipReveal, !newOnes.isEmpty {
                onNewInboxFromBackgroundPoll?()
            }
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
