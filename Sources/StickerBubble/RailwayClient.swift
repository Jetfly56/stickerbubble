import Foundation

enum RailwayClientError: LocalizedError {
    case invalidBaseURL
    case httpStatus(Int)
    case decoding
    case emptyBody
    case serverMessage(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid server URL."
        case .httpStatus(let c): return "Server returned \(c)."
        case .decoding: return "Could not read server response."
        case .emptyBody: return "Empty response."
        case .serverMessage(let s): return s
        }
    }
}

struct RailwayRemoteContact: Codable, Identifiable, Equatable {
    let id: Int
    let peerUserId: String
    let displayName: String
}

/// Someone asked to connect; you must accept (or decline).
struct RailwayContactRequestIncoming: Codable, Identifiable, Equatable {
    let id: Int
    let fromUserId: String
    let peerDisplayName: String
}

/// You asked to connect; waiting on them.
struct RailwayContactRequestOutgoing: Codable, Identifiable, Equatable {
    let id: Int
    let toUserId: String
    let peerDisplayName: String
}

enum RailwayUpsertContactResult: Equatable {
    /// Already had this peer in your contacts.
    case alreadyInContacts
    /// Invite is waiting on the other person.
    case invitePending
    /// You were linked (you accepted, or you confirmed an invite they sent).
    case becameContacts
}

struct RailwayInboxMessage: Codable, Equatable {
    let id: Int64
    let senderUserId: String
    let stickerUrl: String?
    let body: String?
    let senderDisplayName: String?
}

struct RailwayAuthAccount: Codable, Equatable {
    let userId: String
    let displayName: String
}

/// Minimal public profile returned for add-contact confirmation (must be signed in).
struct RailwayPeerPublicProfile: Codable, Equatable {
    let userId: String
    let displayName: String
}

struct RailwayAuthResponse: Codable {
    let token: String
    let account: RailwayAuthAccount
}

struct RailwayMeResponse: Codable {
    let userId: String
    let displayName: String
    let devices: [RailwayDeviceRow]
}

struct RailwayDeviceRow: Codable, Equatable {
    let deviceToken: String
    let label: String
}

enum RailwayClient {
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func joinURL(base: String, path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + path) else { throw RailwayClientError.invalidBaseURL }
        return url
    }

    private static func applyAuth(_ req: inout URLRequest, token: String?) {
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return }
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
    }

    private static func serverErrorMessage(data: Data, status: Int) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? String
        else { return nil }
        return "\(err) (\(status))"
    }

    // MARK: - Auth

    static func register(
        baseURL: String,
        userId: String,
        password: String,
        displayName: String?,
        deviceToken: String,
        deviceLabel: String?
    ) async throws -> RailwayAuthResponse {
        let url = try joinURL(base: baseURL, path: "/api/auth/register")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let userId: String
            let password: String
            let displayName: String?
            let deviceToken: String
            let deviceLabel: String?
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(
            userId: userId,
            password: password,
            displayName: displayName,
            deviceToken: deviceToken,
            deviceLabel: deviceLabel
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        return try decoder().decode(RailwayAuthResponse.self, from: data)
    }

    static func login(
        baseURL: String,
        userId: String,
        password: String,
        deviceToken: String,
        deviceLabel: String?
    ) async throws -> RailwayAuthResponse {
        let url = try joinURL(base: baseURL, path: "/api/auth/login")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let userId: String
            let password: String
            let deviceToken: String
            let deviceLabel: String?
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(userId: userId, password: password, deviceToken: deviceToken, deviceLabel: deviceLabel))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        return try decoder().decode(RailwayAuthResponse.self, from: data)
    }

    static func changePassword(baseURL: String, token: String, oldPassword: String, newPassword: String) async throws {
        let url = try joinURL(base: baseURL, path: "/api/auth/change-password")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, token: token)
        struct Body: Encodable {
            let oldPassword: String
            let newPassword: String
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(oldPassword: oldPassword, newPassword: newPassword))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func createRecoveryCode(baseURL: String, token: String) async throws -> (code: String, expiresAt: String) {
        let url = try joinURL(base: baseURL, path: "/api/auth/recovery-code")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable { let code: String; let expiresAt: String }
        let root = try decoder().decode(Root.self, from: data)
        return (root.code, root.expiresAt)
    }

    static func recover(
        baseURL: String,
        userId: String,
        code: String,
        newPassword: String,
        deviceToken: String,
        deviceLabel: String?
    ) async throws -> RailwayAuthResponse {
        let url = try joinURL(base: baseURL, path: "/api/auth/recover")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let userId: String
            let code: String
            let newPassword: String
            let deviceToken: String
            let deviceLabel: String?
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(
            userId: userId,
            code: code,
            newPassword: newPassword,
            deviceToken: deviceToken,
            deviceLabel: deviceLabel
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        return try decoder().decode(RailwayAuthResponse.self, from: data)
    }

    static func fetchMe(baseURL: String, token: String) async throws -> RailwayMeResponse {
        let url = try joinURL(base: baseURL, path: "/api/me")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        return try decoder().decode(RailwayMeResponse.self, from: data)
    }

    /// Returns `nil` when no account exists with this user ID (`404`).
    static func fetchPeerPublicProfile(baseURL: String, token: String, normalizedUserId: String) async throws -> RailwayPeerPublicProfile? {
        let endpoint = try joinURL(base: baseURL, path: "/api/users/lookup")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw RailwayClientError.invalidBaseURL
        }
        components.queryItems = [URLQueryItem(name: "user_id", value: normalizedUserId)]
        guard let url = components.url else { throw RailwayClientError.invalidBaseURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        if http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200 else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        return try decoder().decode(RailwayPeerPublicProfile.self, from: data)
    }

    static func patchDisplayName(baseURL: String, token: String, displayName: String) async throws -> RailwayAuthAccount {
        let url = try joinURL(base: baseURL, path: "/api/me")
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, token: token)
        struct Body: Encodable { let displayName: String }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(displayName: displayName))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable { let account: RailwayAuthAccount }
        return try decoder().decode(Root.self, from: data).account
    }

    // MARK: - Contacts & inbox

    static func fetchContactRequests(
        baseURL: String,
        token: String
    ) async throws -> (incoming: [RailwayContactRequestIncoming], outgoing: [RailwayContactRequestOutgoing]) {
        let url = try joinURL(base: baseURL, path: "/api/contacts/requests")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable {
            let incoming: [RailwayContactRequestIncoming]
            let outgoing: [RailwayContactRequestOutgoing]
        }
        let root = try decoder().decode(Root.self, from: data)
        return (root.incoming, root.outgoing)
    }

    static func fetchContacts(baseURL: String, token: String) async throws -> [RailwayRemoteContact] {
        let url = try joinURL(base: baseURL, path: "/api/contacts")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable { let contacts: [RailwayRemoteContact] }
        return try decoder().decode(Root.self, from: data).contacts
    }

    static func fetchInbox(baseURL: String, token: String, afterId: Int64) async throws -> [RailwayInboxMessage] {
        let url = try joinURL(base: baseURL, path: "/api/messages/inbox?after_id=\(afterId)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable { let messages: [RailwayInboxMessage] }
        return try decoder().decode(Root.self, from: data).messages
    }

    static func postMessage(
        baseURL: String,
        token: String,
        recipientUserId: String,
        stickerURL: String?,
        body: String?,
        mediaBase64: String?,
        mediaContentType: String?,
        senderDisplayName: String?
    ) async throws {
        let url = try joinURL(base: baseURL, path: "/api/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, token: token)
        struct Body: Encodable {
            let recipientUserId: String
            let stickerUrl: String?
            let body: String?
            let mediaBase64: String?
            let mediaContentType: String?
            let senderDisplayName: String?
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(
            recipientUserId: recipientUserId,
            stickerUrl: stickerURL,
            body: body,
            mediaBase64: mediaBase64,
            mediaContentType: mediaContentType,
            senderDisplayName: senderDisplayName
        ))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func upsertContact(
        baseURL: String,
        token: String,
        peerUserId: String,
        displayName: String
    ) async throws -> RailwayUpsertContactResult {
        let url = try joinURL(base: baseURL, path: "/api/contacts")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, token: token)
        struct Body: Encodable {
            let peerUserId: String
            let displayName: String
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(peerUserId: peerUserId, displayName: displayName))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
        struct Root: Decodable {
            let outcome: String?
            let contact: RailwayRemoteContact?
        }
        let root = try decoder().decode(Root.self, from: data)
        if root.outcome == "pending" {
            return .invitePending
        }
        if root.outcome == "accepted_incoming" {
            return .becameContacts
        }
        if root.contact != nil {
            return .alreadyInContacts
        }
        return .invitePending
    }

    static func acceptContactRequest(baseURL: String, token: String, requestId: Int, displayNameForRequester: String) async throws {
        let url = try joinURL(base: baseURL, path: "/api/contacts/requests/\(requestId)/accept")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuth(&req, token: token)
        struct Body: Encodable { let displayName: String }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(displayName: displayNameForRequester))
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func declineContactRequest(baseURL: String, token: String, requestId: Int) async throws {
        let url = try joinURL(base: baseURL, path: "/api/contacts/requests/\(requestId)/decline")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func cancelOutgoingContactRequest(baseURL: String, token: String, requestId: Int) async throws {
        let url = try joinURL(base: baseURL, path: "/api/contacts/requests/\(requestId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func deleteContact(baseURL: String, token: String, contactId: Int) async throws {
        let url = try joinURL(base: baseURL, path: "/api/contacts/\(contactId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func deleteInboxMessage(baseURL: String, token: String, messageId: Int64) async throws {
        let url = try joinURL(base: baseURL, path: "/api/messages/\(messageId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }

    static func clearInbox(baseURL: String, token: String) async throws {
        let url = try joinURL(base: baseURL, path: "/api/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        applyAuth(&req, token: token)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else {
            throw RailwayClientError.serverMessage(serverErrorMessage(data: data, status: http.statusCode) ?? "HTTP \(http.statusCode)")
        }
    }
}
