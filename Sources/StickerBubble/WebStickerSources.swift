import Foundation

enum WebStickerProvider: String, CaseIterable, Identifiable {
    case redditGifs = "Reddit · r/gifs"
    case redditMemes = "Reddit · r/memes"
    case redditReaction = "Reddit · r/reactiongifs"
    case giphyTrending = "Giphy · Trending"
    case giphySearch = "Giphy · Search"

    var id: String { rawValue }

    var isReddit: Bool {
        switch self {
        case .redditGifs, .redditMemes, .redditReaction: return true
        default: return false
        }
    }

    var isGiphy: Bool {
        switch self {
        case .giphyTrending, .giphySearch: return true
        default: return false
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
        case .emptyQuery: return "Enter a search term for Giphy search."
        case .invalidURL: return "Bad URL."
        }
    }
}

extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
