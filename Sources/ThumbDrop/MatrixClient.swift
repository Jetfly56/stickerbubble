import Foundation

/// Minimal Matrix Client-Server v3 client for sending and receiving stickers.
/// Works against any Matrix-compliant homeserver (matrix.org, Beeper / hungryserv at
/// matrix.beeper.com, self-hosted Synapse / Conduit, etc). Unencrypted rooms only.
enum MatrixClientError: LocalizedError {
    case invalidURL
    case httpStatus(Int, String?)
    case decoding
    case mediaUploadFailed(Int)
    case downloadFailed
    case malformedMxc

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Matrix URL."
        case .httpStatus(let c, let m):
            if let m, !m.isEmpty { return "Matrix server: \(m) (\(c))" }
            return "Matrix server returned \(c)."
        case .decoding: return "Could not parse Matrix response."
        case .mediaUploadFailed(let c): return "Matrix media upload failed (\(c))."
        case .downloadFailed: return "Failed to download Matrix media."
        case .malformedMxc: return "Malformed mxc URL."
        }
    }
}

struct MatrixLoginResponse: Decodable, Equatable {
    let userId: String
    let accessToken: String
    let deviceId: String

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case accessToken = "access_token"
        case deviceId = "device_id"
    }
}

struct MatrixRoom: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

struct MatrixIncomingEvent: Equatable {
    let eventId: String
    let roomId: String
    let senderUserId: String
    /// mxc:// URL when the event carries an image/sticker; nil for plain text.
    let mxcURL: String?
    let body: String?
    let originServerTs: Int64
    /// Optional pan offset stamped on outgoing events (in display points). Allows the
    /// receiver to reproduce the sender's chosen view of an oversized sticker.
    let panOffsetX: Double?
    let panOffsetY: Double?
    /// Optional zoom factor; nil/missing means 1.0.
    let scale: Double?
}

struct MatrixSyncResult: Equatable {
    let nextBatch: String
    let events: [MatrixIncomingEvent]
}

enum MatrixClient {
    static let defaultHomeserverURL = "https://matrix.org"
    static let beeperHomeserverURL = "https://matrix.beeper.com"

    /// Custom content marker stamped onto every event ThumbDrop sends. The inbox poll filters
    /// incoming sync to only include events that carry this key, so unrelated Matrix traffic
    /// (iMessage/WhatsApp bridges, vanilla chat clients, automation bots) is ignored.
    static let thumbDropContentKey = "com.thumbdrop.app"
    static let thumbDropContentValue = "v1"
    static let thumbDropPanXKey = "com.thumbdrop.pan_x"
    static let thumbDropPanYKey = "com.thumbdrop.pan_y"
    static let thumbDropScaleKey = "com.thumbdrop.scale"

    /// Trims and strips trailing slashes from a homeserver URL.
    static func normalizeHomeserverURL(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !(s.hasPrefix("http://") || s.hasPrefix("https://")) {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard URL(string: s) != nil else { return nil }
        return s
    }

    private static func endpoint(_ homeserverURL: String, path: String, query: [URLQueryItem] = []) throws -> URL {
        guard let base = normalizeHomeserverURL(homeserverURL),
              var comps = URLComponents(string: base + path)
        else { throw MatrixClientError.invalidURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw MatrixClientError.invalidURL }
        return url
    }

    private static func authed(_ req: inout URLRequest, _ token: String) {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private static func httpError(data: Data, response: URLResponse?) -> MatrixClientError {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? String
        {
            return .httpStatus(code, err)
        }
        return .httpStatus(code, nil)
    }

    /// Stable negative Int64 from a Matrix event id; used as a deterministic local inbox key
    /// that stays deduped across sync calls.
    static func stableNegativeId(eventId: String) -> Int64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in eventId.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        let positive = hash >> 1
        return positive == 0 ? -1 : -Int64(positive)
    }

    private static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - Auth

    static func login(homeserverURL: String, username: String, password: String) async throws -> MatrixLoginResponse {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "type": "m.login.password",
            "identifier": ["type": "m.id.user", "user": username],
            "password": password,
            "initial_device_display_name": "ThumbDrop on Mac",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw httpError(data: data, response: response)
        }
        return try JSONDecoder().decode(MatrixLoginResponse.self, from: data)
    }

    /// Validates an existing access token and returns the user id (and optional device id).
    /// Use this for Beeper / hungryserv accounts where login is mediated by a cloud auth flow
    /// and the user can paste a token from their existing client.
    static func whoami(homeserverURL: String, accessToken: String) async throws -> (userId: String, deviceId: String) {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/account/whoami")
        var req = URLRequest(url: url)
        authed(&req, accessToken)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw httpError(data: data, response: response)
        }
        struct Root: Decodable { let user_id: String; let device_id: String? }
        let r = try JSONDecoder().decode(Root.self, from: data)
        return (r.user_id, r.device_id ?? "")
    }

    /// Best-effort logout. Network errors are swallowed; the caller wipes local creds either way.
    static func logout(homeserverURL: String, accessToken: String) async {
        guard let url = try? endpoint(homeserverURL, path: "/_matrix/client/v3/logout") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        authed(&req, accessToken)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Rooms

    static func joinedRoomIds(homeserverURL: String, accessToken: String) async throws -> [String] {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/joined_rooms")
        var req = URLRequest(url: url)
        authed(&req, accessToken)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw httpError(data: data, response: response)
        }
        struct Root: Decodable { let joined_rooms: [String] }
        return try JSONDecoder().decode(Root.self, from: data).joined_rooms
    }

    /// Returns the room's display name. Falls back to canonical alias, then the room id itself.
    static func roomDisplayName(homeserverURL: String, accessToken: String, roomId: String) async -> String {
        let escapedRoom = pathEscape(roomId)

        if let nameURL = try? endpoint(homeserverURL, path: "/_matrix/client/v3/rooms/\(escapedRoom)/state/m.room.name/") {
            var req = URLRequest(url: nameURL)
            authed(&req, accessToken)
            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let n = (obj["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !n.isEmpty
            {
                return n
            }
        }

        if let aliasURL = try? endpoint(homeserverURL, path: "/_matrix/client/v3/rooms/\(escapedRoom)/state/m.room.canonical_alias/") {
            var req = URLRequest(url: aliasURL)
            authed(&req, accessToken)
            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, http.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let alias = (obj["alias"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !alias.isEmpty
            {
                return alias
            }
        }

        return roomId
    }

    static func joinedRoomsWithNames(homeserverURL: String, accessToken: String) async throws -> [MatrixRoom] {
        let ids = try await joinedRoomIds(homeserverURL: homeserverURL, accessToken: accessToken)
        var out: [MatrixRoom] = []
        out.reserveCapacity(ids.count)
        await withTaskGroup(of: MatrixRoom.self) { group in
            for id in ids {
                group.addTask {
                    let name = await roomDisplayName(homeserverURL: homeserverURL, accessToken: accessToken, roomId: id)
                    return MatrixRoom(id: id, name: name)
                }
            }
            for await room in group {
                out.append(room)
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Media

    /// Uploads bytes to the media repo. Returns the resulting `mxc://` URI.
    static func uploadMedia(
        homeserverURL: String,
        accessToken: String,
        data: Data,
        contentType: String,
        filename: String
    ) async throws -> String {
        let url = try endpoint(
            homeserverURL,
            path: "/_matrix/media/v3/upload",
            query: [URLQueryItem(name: "filename", value: filename)]
        )
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        authed(&req, accessToken)
        let (respData, response) = try await URLSession.shared.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw MatrixClientError.mediaUploadFailed((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        struct Root: Decodable { let content_uri: String }
        return try JSONDecoder().decode(Root.self, from: respData).content_uri
    }

    /// Downloads an mxc URL. Tries the authenticated endpoint first (Matrix 1.11+),
    /// falls back to the legacy unauth endpoint for grandfathered media.
    static func downloadMedia(homeserverURL: String, accessToken: String, mxcURL: String) async throws -> (Data, String?) {
        guard mxcURL.hasPrefix("mxc://") else { throw MatrixClientError.malformedMxc }
        let stripped = String(mxcURL.dropFirst("mxc://".count))
        let parts = stripped.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw MatrixClientError.malformedMxc }
        let server = pathEscape(String(parts[0]))
        let mediaId = pathEscape(String(parts[1]))
        guard let base = normalizeHomeserverURL(homeserverURL) else {
            throw MatrixClientError.invalidURL
        }

        if let url = URL(string: base + "/_matrix/client/v1/media/download/\(server)/\(mediaId)") {
            var req = URLRequest(url: url)
            authed(&req, accessToken)
            req.timeoutInterval = 30
            if let (data, response) = try? await URLSession.shared.data(for: req),
               let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode)
            {
                return (data, http.value(forHTTPHeaderField: "Content-Type"))
            }
        }

        if let url = URL(string: base + "/_matrix/media/v3/download/\(server)/\(mediaId)") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
                throw MatrixClientError.downloadFailed
            }
            return (data, http.value(forHTTPHeaderField: "Content-Type"))
        }

        throw MatrixClientError.downloadFailed
    }

    // MARK: - Send

    private static func putEvent(
        homeserverURL: String,
        accessToken: String,
        roomId: String,
        eventType: String,
        txnId: String,
        content: [String: Any]
    ) async throws {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/rooms/\(pathEscape(roomId))/send/\(eventType)/\(pathEscape(txnId))")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req, accessToken)
        req.httpBody = try JSONSerialization.data(withJSONObject: content)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw httpError(data: data, response: response)
        }
    }

    /// Tucks our custom marker + optional pan/scale into the spec-flexible `info` sub-object.
    /// Pan is encoded as rounded **integer** pixels and scale as **integer** milli-scale
    /// (i.e. value × 1000). Hungryserv / Beeper rejects events that put floats anywhere
    /// inside the event content with "bad json value (float)", so everything goes out as
    /// strings or ints — no Doubles touch the wire.
    static let thumbDropScaleScaleFactor: Double = 1000.0

    private static func decoratedInfo(_ info: [String: Any], panOffset: CGSize?, scale: CGFloat?) -> [String: Any] {
        var out = info
        out[thumbDropContentKey] = thumbDropContentValue
        if let pan = panOffset, pan != .zero {
            out[thumbDropPanXKey] = Int(pan.width.rounded())
            out[thumbDropPanYKey] = Int(pan.height.rounded())
        }
        if let s = scale, abs(s - 1) > 0.001 {
            out[thumbDropScaleKey] = Int((Double(s) * thumbDropScaleScaleFactor).rounded())
        }
        return out
    }

    static func sendSticker(
        homeserverURL: String,
        accessToken: String,
        roomId: String,
        mxcURL: String,
        info: [String: Any],
        body: String,
        panOffset: CGSize? = nil,
        scale: CGFloat? = nil
    ) async throws {
        let decorated = decoratedInfo(info, panOffset: panOffset, scale: scale)
        try await putEvent(
            homeserverURL: homeserverURL,
            accessToken: accessToken,
            roomId: roomId,
            eventType: "m.sticker",
            txnId: "thumbdrop-\(UUID().uuidString)",
            content: [
                "body": body,
                "url": mxcURL,
                "info": decorated,
            ]
        )
    }

    static func sendImage(
        homeserverURL: String,
        accessToken: String,
        roomId: String,
        mxcURL: String,
        info: [String: Any],
        body: String,
        panOffset: CGSize? = nil,
        scale: CGFloat? = nil
    ) async throws {
        let decorated = decoratedInfo(info, panOffset: panOffset, scale: scale)
        try await putEvent(
            homeserverURL: homeserverURL,
            accessToken: accessToken,
            roomId: roomId,
            eventType: "m.room.message",
            txnId: "thumbdrop-\(UUID().uuidString)",
            content: [
                "msgtype": "m.image",
                "body": body,
                "url": mxcURL,
                "info": decorated,
            ]
        )
    }

    static func sendText(
        homeserverURL: String,
        accessToken: String,
        roomId: String,
        body: String
    ) async throws {
        try await putEvent(
            homeserverURL: homeserverURL,
            accessToken: accessToken,
            roomId: roomId,
            eventType: "m.room.message",
            txnId: "thumbdrop-\(UUID().uuidString)",
            content: [
                "msgtype": "m.text",
                "body": body,
                thumbDropContentKey: thumbDropContentValue,
            ]
        )
    }

    // MARK: - Sync

    /// Long-poll sync. Returns the new `next_batch` token plus any incoming sticker / image / text
    /// events from joined rooms. Events authored by `ownUserId` are skipped, except in rooms
    /// listed in `selfRoomIds` (self-DMs / "Notes to self") where we want to surface them so
    /// the user sees their own messages from other devices.
    static func sync(
        homeserverURL: String,
        accessToken: String,
        since: String?,
        timeoutMs: Int,
        ownUserId: String,
        selfRoomIds: Set<String> = []
    ) async throws -> MatrixSyncResult {
        var query: [URLQueryItem] = [URLQueryItem(name: "timeout", value: String(timeoutMs))]
        if let since, !since.isEmpty {
            query.append(URLQueryItem(name: "since", value: since))
        }
        let filter = #"{"room":{"timeline":{"types":["m.sticker","m.room.message"],"limit":50},"state":{"types":[]},"ephemeral":{"types":[]},"account_data":{"types":[]}},"presence":{"types":[]},"account_data":{"types":[]}}"#
        query.append(URLQueryItem(name: "filter", value: filter))

        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/sync", query: query)
        var req = URLRequest(url: url)
        authed(&req, accessToken)
        req.timeoutInterval = TimeInterval(timeoutMs / 1000) + 20

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw httpError(data: data, response: response)
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MatrixClientError.decoding
        }
        let nextBatch = (root["next_batch"] as? String) ?? since ?? ""

        var events: [MatrixIncomingEvent] = []
        if let rooms = root["rooms"] as? [String: Any],
           let joined = rooms["join"] as? [String: Any]
        {
            for (roomId, rawRoom) in joined {
                guard let room = rawRoom as? [String: Any],
                      let timeline = room["timeline"] as? [String: Any],
                      let timelineEvents = timeline["events"] as? [[String: Any]] else { continue }
                for ev in timelineEvents {
                    guard let type = ev["type"] as? String,
                          let eventId = ev["event_id"] as? String,
                          let sender = ev["sender"] as? String,
                          let content = ev["content"] as? [String: Any] else { continue }
                    if sender == ownUserId, !selfRoomIds.contains(roomId) { continue }

                    // Custom fields live inside `info` (current shape) but fall back to top-level
                    // for any messages sent before that move, and to support text events.
                    let info = content["info"] as? [String: Any]
                    let hasMarker = (info?[thumbDropContentKey] != nil) || (content[thumbDropContentKey] != nil)
                    guard hasMarker else { continue }
                    let ts = (ev["origin_server_ts"] as? Int64)
                        ?? Int64((ev["origin_server_ts"] as? Double) ?? 0)

                    func numericFromContent(_ key: String) -> Double? {
                        if let info, let d = info[key] as? Double { return d }
                        if let info, let i = info[key] as? Int { return Double(i) }
                        if let d = content[key] as? Double { return d }
                        if let i = content[key] as? Int { return Double(i) }
                        return nil
                    }
                    let panX = numericFromContent(thumbDropPanXKey)
                    let panY = numericFromContent(thumbDropPanYKey)
                    // Scale is sent as integer milli-scale; restore to a real ratio. A raw
                    // value > ~10 means the sender used the new int-encoded form (and a
                    // value of, say, 1500 becomes 1.5). Smaller values are legacy floats.
                    let rawScale = numericFromContent(thumbDropScaleKey)
                    let scale: Double? = rawScale.map { v in
                        v > 10 ? v / thumbDropScaleScaleFactor : v
                    }

                    if type == "m.sticker" {
                        events.append(MatrixIncomingEvent(
                            eventId: eventId,
                            roomId: roomId,
                            senderUserId: sender,
                            mxcURL: content["url"] as? String,
                            body: content["body"] as? String,
                            originServerTs: ts,
                            panOffsetX: panX,
                            panOffsetY: panY,
                            scale: scale
                        ))
                    } else if type == "m.room.message",
                              let msgtype = content["msgtype"] as? String
                    {
                        if msgtype == "m.image" {
                            events.append(MatrixIncomingEvent(
                                eventId: eventId,
                                roomId: roomId,
                                senderUserId: sender,
                                mxcURL: content["url"] as? String,
                                body: content["body"] as? String,
                                originServerTs: ts,
                                panOffsetX: panX,
                                panOffsetY: panY,
                                scale: scale
                            ))
                        } else if msgtype == "m.text" {
                            events.append(MatrixIncomingEvent(
                                eventId: eventId,
                                roomId: roomId,
                                senderUserId: sender,
                                mxcURL: nil,
                                body: content["body"] as? String,
                                originServerTs: ts,
                                panOffsetX: nil,
                                panOffsetY: nil,
                                scale: nil
                            ))
                        }
                    }
                }
            }
        }
        return MatrixSyncResult(
            nextBatch: nextBatch,
            events: events.sorted { $0.originServerTs < $1.originServerTs }
        )
    }

    // MARK: - Direct messages (m.direct)

    /// Reads the user's `m.direct` account data, mapping peer MXID → list of room ids that are DMs with them.
    /// A 404 (account data not yet set) is treated as an empty map.
    static func getDirectRoomsMap(homeserverURL: String, accessToken: String, userId: String) async throws -> [String: [String]] {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/user/\(pathEscape(userId))/account_data/m.direct")
        var req = URLRequest(url: url)
        authed(&req, accessToken)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw MatrixClientError.httpStatus(-1, nil) }
        if http.statusCode == 404 { return [:] }
        guard http.statusCode == 200 else { throw httpError(data: data, response: response) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MatrixClientError.decoding
        }
        var result: [String: [String]] = [:]
        for (k, v) in obj {
            if let rooms = v as? [String] { result[k] = rooms }
        }
        return result
    }

    static func setDirectRoomsMap(homeserverURL: String, accessToken: String, userId: String, map: [String: [String]]) async throws {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/user/\(pathEscape(userId))/account_data/m.direct")
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req, accessToken)
        req.httpBody = try JSONSerialization.data(withJSONObject: map)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw httpError(data: data, response: response)
        }
    }

    /// Creates a "Notes" / self-DM room with no invitees. The signed-in user is the sole member.
    static func createSelfRoom(homeserverURL: String, accessToken: String) async throws -> String {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/createRoom")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req, accessToken)
        let body: [String: Any] = [
            "preset": "trusted_private_chat",
            "is_direct": true,
            "visibility": "private",
            "name": "Notes",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw httpError(data: data, response: response)
        }
        struct Root: Decodable { let room_id: String }
        return try JSONDecoder().decode(Root.self, from: data).room_id
    }

    /// Creates a private 1-1 room and invites the peer. Uses `trusted_private_chat` (invite-only join,
    /// shared history for invitees). Returns the new room id.
    static func createDirectRoom(homeserverURL: String, accessToken: String, peerMxid: String) async throws -> String {
        let url = try endpoint(homeserverURL, path: "/_matrix/client/v3/createRoom")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authed(&req, accessToken)
        let body: [String: Any] = [
            "preset": "trusted_private_chat",
            "invite": [peerMxid],
            "is_direct": true,
            "visibility": "private",
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw httpError(data: data, response: response)
        }
        struct Root: Decodable { let room_id: String }
        return try JSONDecoder().decode(Root.self, from: data).room_id
    }

    // MARK: - Profile

    static func displayName(homeserverURL: String, accessToken: String, userId: String) async -> String? {
        guard let url = try? endpoint(homeserverURL, path: "/_matrix/client/v3/profile/\(pathEscape(userId))/displayname") else {
            return nil
        }
        var req = URLRequest(url: url)
        authed(&req, accessToken)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let n = (obj["displayname"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (n?.isEmpty == false) ? n : nil
    }
}
