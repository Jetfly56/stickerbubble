import Foundation

enum RailwayClientError: LocalizedError {
    case invalidBaseURL
    case httpStatus(Int)
    case decoding
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Invalid server URL."
        case .httpStatus(let c): return "Server returned \(c)."
        case .decoding: return "Could not read server response."
        case .emptyBody: return "Empty response."
        }
    }
}

struct RailwayRemoteContact: Codable, Identifiable, Equatable {
    let id: Int
    let peerDeviceId: String
    let displayName: String
}

struct RailwayInboxMessage: Codable, Equatable {
    let id: Int64
    let senderDeviceId: String
    let recipientDeviceId: String
    let stickerUrl: String?
    let body: String?
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

    static func fetchContacts(baseURL: String, deviceId: String) async throws -> [RailwayRemoteContact] {
        let url = try joinURL(base: baseURL, path: "/api/contacts?device_id=\(deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId)")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else { throw RailwayClientError.httpStatus(http.statusCode) }
        struct Root: Decodable { let contacts: [RailwayRemoteContact] }
        return try decoder().decode(Root.self, from: data).contacts
    }

    static func fetchInbox(baseURL: String, deviceId: String, afterId: Int64) async throws -> [RailwayInboxMessage] {
        let enc = deviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceId
        let url = try joinURL(base: baseURL, path: "/api/messages/inbox?device_id=\(enc)&after_id=\(afterId)")
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard http.statusCode == 200 else { throw RailwayClientError.httpStatus(http.statusCode) }
        struct Root: Decodable { let messages: [RailwayInboxMessage] }
        return try decoder().decode(Root.self, from: data).messages
    }

    static func postMessage(
        baseURL: String,
        senderDeviceId: String,
        recipientDeviceId: String,
        stickerURL: String?,
        body: String?,
        mediaBase64: String?,
        mediaContentType: String?
    ) async throws {
        let url = try joinURL(base: baseURL, path: "/api/messages")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable {
            let senderDeviceId: String
            let recipientDeviceId: String
            let stickerUrl: String?
            let body: String?
            let mediaBase64: String?
            let mediaContentType: String?
        }

        let payload = Body(
            senderDeviceId: senderDeviceId,
            recipientDeviceId: recipientDeviceId,
            stickerUrl: stickerURL,
            body: body,
            mediaBase64: mediaBase64,
            mediaContentType: mediaContentType
        )
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(payload)

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else { throw RailwayClientError.httpStatus(http.statusCode) }
    }

    static func upsertContact(
        baseURL: String,
        ownerDeviceId: String,
        peerDeviceId: String,
        displayName: String
    ) async throws {
        let url = try joinURL(base: baseURL, path: "/api/contacts")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        struct Body: Encodable {
            let ownerDeviceId: String
            let peerDeviceId: String
            let displayName: String
        }
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(Body(ownerDeviceId: ownerDeviceId, peerDeviceId: peerDeviceId, displayName: displayName))
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else { throw RailwayClientError.httpStatus(http.statusCode) }
    }

    static func deleteContact(baseURL: String, ownerDeviceId: String, contactId: Int) async throws {
        let enc = ownerDeviceId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ownerDeviceId
        let url = try joinURL(base: baseURL, path: "/api/contacts/\(contactId)?device_id=\(enc)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw RailwayClientError.httpStatus(-1) }
        guard (200 ... 299).contains(http.statusCode) else { throw RailwayClientError.httpStatus(http.statusCode) }
    }
}
