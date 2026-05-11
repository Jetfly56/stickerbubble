import Foundation

enum WebStickerProvider: String, CaseIterable, Identifiable {
    case redditGifs = "Reddit · r/gifs"
    case redditMemes = "Reddit · r/memes"
    case redditReaction = "Reddit · r/reactiongifs"
    case giphy = "Giphy"

    var id: String { rawValue }

    var isReddit: Bool { subreddit != nil }

    var isGiphy: Bool { self == .giphy }

    var subreddit: String? {
        switch self {
        case .redditGifs: return "gifs"
        case .redditMemes: return "memes"
        case .redditReaction: return "reactiongifs"
        case .giphy: return nil
        }
    }

    /// Placeholder shown in the search field when this source is selected.
    var searchPlaceholder: String {
        switch self {
        case .giphy: return "Search Giphy (empty for trending)"
        default: return "Search \(rawValue) (empty for hot)"
        }
    }
}

struct WebStickerItem: Identifiable, Equatable {
    let id: String
    let title: String
    let previewURL: URL?
    /// Direct media URL suitable for loading with `StickerDisplay` (`.url`).
    let mediaURL: URL
}

enum WebStickerFetchError: LocalizedError {
    case badResponse(Int)
    case decode
    case noGIFKey
    case emptyQuery
    case invalidURL

    var errorDescription: String? {
        switch self {
        case .badResponse(let code): return "Server returned \(code)."
        case .decode: return "Could not parse the response."
        case .noGIFKey: return "Add a Giphy API key (free at developers.giphy.com) below."
        case .emptyQuery: return "Enter a search term."
        case .invalidURL: return "Bad URL."
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
