import AppKit
import SwiftUI

enum MusicLinkService {
    case appleMusic
    case spotify
    case youtube
    case youtubeMusic

    init?(url: URL) {
        guard let host = url.host?.lowercased() else { return nil }
        if host.contains("music.apple.com") { self = .appleMusic; return }
        if host.contains("open.spotify.com") || host == "spotify.com" || host.hasSuffix(".spotify.com") { self = .spotify; return }
        if host == "music.youtube.com" { self = .youtubeMusic; return }
        if host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") { self = .youtube; return }
        return nil
    }

    var displayName: String {
        switch self {
        case .appleMusic:    return "Apple Music"
        case .spotify:       return "Spotify"
        case .youtube:       return "YouTube"
        case .youtubeMusic:  return "YouTube Music"
        }
    }

    var accent: Color {
        switch self {
        case .appleMusic:    return Color(red: 0.97, green: 0.18, blue: 0.42)
        case .spotify:       return Color(red: 0.11, green: 0.84, blue: 0.38)
        case .youtube:       return Color(red: 1.0, green: 0.0, blue: 0.0)
        case .youtubeMusic:  return Color(red: 1.0, green: 0.0, blue: 0.0)
        }
    }

    var symbol: String {
        switch self {
        case .appleMusic:                 return "music.note"
        case .spotify, .youtubeMusic:     return "music.note.list"
        case .youtube:                    return "play.rectangle.fill"
        }
    }
}

struct MusicLinkMetadata: Equatable {
    let title: String?
    let subtitle: String?
    let imageURL: URL?
}

@MainActor
final class MusicLinkLoader: ObservableObject {
    @Published private(set) var metadata: MusicLinkMetadata?
    @Published private(set) var isLoading = false
    @Published private(set) var failed = false
    private var loadedKey: String?

    func load(_ url: URL) {
        let key = url.absoluteString
        if loadedKey == key { return }
        loadedKey = key
        metadata = nil
        failed = false
        isLoading = true
        Task { [weak self] in
            await self?.fetch(url: url, key: key)
        }
    }

    private func fetch(url: URL, key: String) async {
        defer { Task { @MainActor in if self.loadedKey == key { self.isLoading = false } } }
        do {
            var req = URLRequest(url: url)
            req.setValue("Mozilla/5.0 (Macintosh) ThumbDrop/1.0", forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
            let title = Self.metaContent(html, property: "og:title") ?? Self.metaContent(html, property: "twitter:title") ?? Self.firstTitleTag(html)
            let imageStr = Self.metaContent(html, property: "og:image") ?? Self.metaContent(html, property: "twitter:image")
            let description = Self.metaContent(html, property: "og:description") ?? Self.metaContent(html, property: "twitter:description")
            let imageURL = imageStr.flatMap(URL.init(string:))
            let meta = MusicLinkMetadata(title: title, subtitle: description, imageURL: imageURL)
            await MainActor.run {
                guard self.loadedKey == key else { return }
                self.metadata = meta
            }
        } catch {
            await MainActor.run {
                guard self.loadedKey == key else { return }
                self.failed = true
            }
        }
    }

    private static func metaContent(_ html: String, property: String) -> String? {
        // Match `<meta property="og:title" ... content="...">` or content first then property
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]*?(?:property|name)=[\"']\(escaped)[\"'][^>]*?content=[\"']([^\"']+)[\"']",
            "<meta[^>]*?content=[\"']([^\"']+)[\"'][^>]*?(?:property|name)=[\"']\(escaped)[\"']",
        ]
        for p in patterns {
            if let regex = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]),
               let m = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
               m.numberOfRanges >= 2,
               let r = Range(m.range(at: 1), in: html)
            {
                return decodeHTMLEntities(String(html[r]))
            }
        }
        return nil
    }

    private static func firstTitleTag(_ html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]+)</title>", options: [.caseInsensitive]),
              let m = regex.firstMatch(in: html, options: [], range: NSRange(html.startIndex..., in: html)),
              m.numberOfRanges >= 2,
              let r = Range(m.range(at: 1), in: html)
        else { return nil }
        return decodeHTMLEntities(String(html[r]).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;",  with: "<")
            .replacingOccurrences(of: "&gt;",  with: ">")
    }
}

struct MusicLinkCard: View {
    let url: URL
    let service: MusicLinkService

    @StateObject private var loader = MusicLinkLoader()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            artworkColumn
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: service.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(service.accent)
                    Text(service.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(service.accent)
                        .textCase(.uppercase)
                }

                Text(loader.metadata?.title ?? (loader.failed ? url.host ?? "Link" : "Loading…"))
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if let sub = loader.metadata?.subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Text("Open")
                        .font(.system(.caption, design: .rounded, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(service.accent.opacity(0.18)))
                        .foregroundStyle(service.accent)
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: StickerCardLayout.mediaTargetWidth)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(service.accent.opacity(0.35), lineWidth: 1))
        .onAppear { loader.load(url) }
        .onChange(of: url) { newURL in loader.load(newURL) }
    }

    @ViewBuilder
    private var artworkColumn: some View {
        if let imageURL = loader.metadata?.imageURL {
            AsyncImage(url: imageURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure, .empty:
                    placeholderArt
                @unknown default:
                    placeholderArt
                }
            }
        } else {
            placeholderArt
        }
    }

    private var placeholderArt: some View {
        ZStack {
            LinearGradient(
                colors: [service.accent.opacity(0.85), service.accent.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: service.symbol)
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
