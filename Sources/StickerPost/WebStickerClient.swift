import Foundation

/// Reddit (no key) + Giphy (paste API key once in-app).
enum WebStickerClient {
    static let redditUserAgent = "StickerBubble/1.0 (macOS sticker utility; Reddit JSON read-only)"

    private static let giphyKeyDefaultsName = "StickerBubble.giphyAPIKey"

    static var giphyAPIKey: String? {
        UserDefaults.standard.string(forKey: giphyKeyDefaultsName)?.nilIfEmpty
    }

    static func saveGiphyAPIKey(_ raw: String) {
        UserDefaults.standard.set(raw.trimmingCharacters(in: .whitespacesAndNewlines), forKey: giphyKeyDefaultsName)
    }

    /// Klipy is fetched through the StickerPost server proxy so users don't have to manage a key.
    private static var klipyProxyBaseURL: String {
        let stored = UserDefaults.standard.string(forKey: "StickerBubble.railwayBaseURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stored, !stored.isEmpty { return stored }
        return "https://stickerbubble-production.up.railway.app"
    }

    static func fetch(
        provider: WebStickerProvider,
        searchQuery: String
    ) async throws -> [WebStickerItem] {
        let trimmed = searchQuery.nilIfEmpty
        if let sub = provider.subreddit {
            return try await fetchReddit(subreddit: sub, query: trimmed)
        }
        if provider.isGiphy {
            if let q = trimmed {
                return try await fetchGiphySearch(q)
            }
            return try await fetchGiphyTrending()
        }
        if provider.isKlipy {
            if let q = trimmed {
                return try await fetchKlipySearch(q)
            }
            return try await fetchKlipyTrending()
        }
        return []
    }

    private static func fetchReddit(subreddit: String, query: String?) async throws -> [WebStickerItem] {
        let path = query == nil ? "hot.json" : "search.json"
        var parts = URLComponents(string: "https://www.reddit.com/r/\(subreddit)/\(path)")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "limit", value: "50"),
            URLQueryItem(name: "raw_json", value: "1"),
        ]
        if let q = query {
            items.append(URLQueryItem(name: "q", value: q))
            items.append(URLQueryItem(name: "restrict_sr", value: "on"))
            items.append(URLQueryItem(name: "sort", value: "hot"))
        }
        parts.queryItems = items
        guard let url = parts.url else { throw WebStickerFetchError.invalidURL }

        var request = URLRequest(url: url)
        request.setValue(redditUserAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw WebStickerFetchError.badResponse(-1) }
        guard http.statusCode == 200 else { throw WebStickerFetchError.badResponse(http.statusCode) }

        let decoded = try JSONDecoder().decode(RedditListingResponse.self, from: data)
        return decoded.extractItems(limit: 36)
    }

    private static func fetchGiphyTrending() async throws -> [WebStickerItem] {
        guard let apiKey = giphyAPIKey else { throw WebStickerFetchError.noGIFKey }

        var parts = URLComponents(string: "https://api.giphy.com/v1/gifs/trending")!
        parts.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "rating", value: "g"),
        ]
        guard let url = parts.url else { throw WebStickerFetchError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WebStickerFetchError.badResponse(-1) }
        guard http.statusCode == 200 else { throw WebStickerFetchError.badResponse(http.statusCode) }

        let decoded = try giphyDecoder().decode(GiphyListResponse.self, from: data)
        return decoded.data.compactMap(\.webItemIfValid)
    }

    private static func fetchGiphySearch(_ query: String) async throws -> [WebStickerItem] {
        guard let apiKey = giphyAPIKey else { throw WebStickerFetchError.noGIFKey }
        guard let trimmed = query.nilIfEmpty else { throw WebStickerFetchError.emptyQuery }

        var parts = URLComponents(string: "https://api.giphy.com/v1/gifs/search")!
        parts.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "limit", value: "30"),
            URLQueryItem(name: "rating", value: "g"),
            URLQueryItem(name: "lang", value: "en"),
        ]
        guard let url = parts.url else { throw WebStickerFetchError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WebStickerFetchError.badResponse(-1) }
        guard http.statusCode == 200 else { throw WebStickerFetchError.badResponse(http.statusCode) }

        let decoded = try giphyDecoder().decode(GiphyListResponse.self, from: data)
        return decoded.data.compactMap(\.webItemIfValid)
    }

    private static func giphyDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }

    private static func fetchKlipyTrending() async throws -> [WebStickerItem] {
        try await fetchKlipy(path: "trending", query: nil)
    }

    private static func fetchKlipySearch(_ query: String) async throws -> [WebStickerItem] {
        guard let trimmed = query.nilIfEmpty else { throw WebStickerFetchError.emptyQuery }
        return try await fetchKlipy(path: "search", query: trimmed)
    }

    private static func fetchKlipy(path: String, query: String?) async throws -> [WebStickerItem] {
        guard var parts = URLComponents(string: "\(klipyProxyBaseURL)/api/klipy/\(path)") else {
            throw WebStickerFetchError.invalidURL
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "per_page", value: "30")]
        if let q = query {
            items.append(URLQueryItem(name: "q", value: q))
        }
        parts.queryItems = items
        guard let url = parts.url else { throw WebStickerFetchError.invalidURL }

        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw WebStickerFetchError.badResponse(-1) }
        guard http.statusCode == 200 else { throw WebStickerFetchError.badResponse(http.statusCode) }

        let decoded = try JSONDecoder().decode(KlipyListResponse.self, from: data)
        return decoded.data.data.compactMap(\.webItemIfValid)
    }
}

// MARK: - Reddit

private struct RedditListingResponse: Decodable {
    let data: ChildWrapper

    struct ChildWrapper: Decodable {
        let children: [Child]
    }

    struct Child: Decodable {
        let data: LinkData?
    }

    struct LinkData: Decodable {
        let title: String?
        let url: String?
        let is_video: Bool?
        let stickied: Bool?
        let is_gallery: Bool?
        let post_hint: String?
        let preview: PreviewBlock?
        let thumbnail: String?
    }

    struct PreviewBlock: Decodable {
        let images: [PreviewImage]

        enum CodingKeys: String, CodingKey {
            case images
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            images = try container.decodeIfPresent([PreviewImage].self, forKey: .images) ?? []
        }

        struct PreviewImage: Decodable {
            let source: SizeURL?
            let resolutions: [SizeURL]?
        }

        struct SizeURL: Decodable {
            let url: String
        }
    }

    func extractItems(limit: Int) -> [WebStickerItem] {
        var out: [WebStickerItem] = []
        let imageExtensions = Set(["gif", "jpg", "jpeg", "png", "webp"])

        for child in data.children {
            guard let link = child.data else { continue }
            if link.stickied == true { continue }
            if link.is_video == true { continue }
            if link.is_gallery == true { continue }

            switch link.post_hint {
            case .some("hosted:video"), .some("rich:video"), .some("reddit:video"):
                continue
            default:
                break
            }

            let previewImg = link.preview?.images.first
            let title = link.title?.nilIfEmpty ?? "Untitled"

            func isDirectImageURL(_ s: String) -> Bool {
                guard let parsed = URL(string: s),
                      parsed.scheme == "https" || parsed.scheme == "http"
                else { return false }

                let ext = parsed.pathExtension.lowercased()
                if imageExtensions.contains(ext), ext != "gifv" {
                    return true
                }

                let lower = s.lowercased()
                if lower.contains("i.redd.it") && imageExtensions.contains(ext) {
                    return true
                }
                return lower.hasSuffix(".gif")
            }

            var mediaURLString: String?

            if let u = link.url?.removingAmpEncoding(), isDirectImageURL(u) {
                mediaURLString = u
            } else if let src = previewImg?.source?.url.removingAmpEncoding(),
                      isDirectImageURL(src)
            {
                mediaURLString = src
            } else if let resolutions = previewImg?.resolutions,
                      let picked = resolutions.last?.url.removingAmpEncoding(),
                      isDirectImageURL(picked)
            {
                mediaURLString = picked
            }

            guard let mediaStr = mediaURLString, let mediaURL = URL(string: mediaStr) else { continue }

            if mediaStr.lowercased().contains(".gifv") { continue }

            let thumbCandidate: URL? = {
                if let resolutions = previewImg?.resolutions,
                   let thumbStr = resolutions.last?.url.removingAmpEncoding(),
                   let u = URL(string: thumbStr)
                {
                    return u
                }
                if let src = previewImg?.source?.url.removingAmpEncoding(),
                   let u = URL(string: src)
                {
                    return u
                }
                if let t = link.thumbnail, t.hasPrefix("http"), let u = URL(string: t) {
                    return u
                }
                return nil
            }()

            let previewURL = thumbCandidate ?? mediaURL
            let id = "\(UUID().uuidString)|\(mediaURL.absoluteString)"

            out.append(WebStickerItem(id: id, title: title, previewURL: previewURL, mediaURL: mediaURL))
            if out.count >= limit { break }
        }

        return out
    }
}

private extension String {
    func removingAmpEncoding() -> String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
    }
}

// MARK: - Giphy

private struct GiphyListResponse: Decodable {
    struct GiphyGif: Decodable {
        struct ImagesPack: Decodable {
            struct ImageRef: Decodable {
                let url: String?
            }

            let fixedHeightSmallStill: ImageRef?
            let fixedHeightSmall: ImageRef?
            let downsizedMedium: ImageRef?
            let original: ImageRef?
        }

        let id: String
        let title: String?
        let images: ImagesPack

        /// Returns `nil` when Giphy sends an unexpected payload.
        var webItemIfValid: WebStickerItem? {
            guard
                let mediaStr = images.original?.url ?? images.downsizedMedium?.url ?? images.fixedHeightSmall?.url,
                let mediaURL = URL(string: mediaStr)
            else { return nil }

            let previewStr = images.fixedHeightSmallStill?.url
                ?? images.fixedHeightSmall?.url
                ?? images.downsizedMedium?.url
                ?? images.original?.url

            let previewURL = previewStr.flatMap { URL(string: $0) } ?? mediaURL
            let t = title?.nilIfEmpty ?? "GIF"
            return WebStickerItem(id: id, title: t, previewURL: previewURL, mediaURL: mediaURL)
        }
    }

    let data: [GiphyGif]
}

// MARK: - Klipy

/// Shape: `{ result, data: { data: [Item], current_page, per_page, has_next } }`.
/// Each item has `file.{hd,md,sm}.{gif,webp,jpg,mp4}.url`.
private struct KlipyListResponse: Decodable {
    struct DataPage: Decodable {
        let data: [Item]
    }

    struct Item: Decodable {
        struct Format: Decodable {
            let url: String?
        }

        struct Variant: Decodable {
            let gif: Format?
            let webp: Format?
            let mp4: Format?
            let jpg: Format?
        }

        struct FileBlock: Decodable {
            let hd: Variant?
            let md: Variant?
            let sm: Variant?
        }

        let id: String?
        let slug: String?
        let title: String?
        let file: FileBlock?

        var webItemIfValid: WebStickerItem? {
            let mediaStr = file?.md?.gif?.url
                ?? file?.hd?.gif?.url
                ?? file?.sm?.gif?.url
            guard let mediaStr, let mediaURL = URL(string: mediaStr) else { return nil }

            let previewStr = file?.sm?.gif?.url
                ?? file?.md?.gif?.url
                ?? file?.hd?.gif?.url
            let previewURL = previewStr.flatMap { URL(string: $0) } ?? mediaURL

            let stableId = id ?? slug ?? mediaStr
            let t = title?.nilIfEmpty ?? "GIF"
            return WebStickerItem(id: stableId, title: t, previewURL: previewURL, mediaURL: mediaURL)
        }
    }

    let data: DataPage
}
