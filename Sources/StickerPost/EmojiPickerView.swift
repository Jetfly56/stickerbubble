import AppKit
import SwiftUI

struct EmojiCategorySpec: Identifiable {
    let id = UUID()
    let name: String
    let symbol: String
    let emojis: [String]
}

enum EmojiCatalog {
    static let categories: [EmojiCategorySpec] = [
        EmojiCategorySpec(name: "Smileys",  symbol: "face.smiling",
                          emojis: emojis(in: [0x1F600...0x1F64F, 0x1F910...0x1F92F, 0x1F970...0x1F97F])),
        EmojiCategorySpec(name: "People",   symbol: "person.fill",
                          emojis: emojis(in: [0x1F464...0x1F487, 0x1F9D0...0x1F9DF, 0x1F574...0x1F57A])),
        EmojiCategorySpec(name: "Animals",  symbol: "pawprint.fill",
                          emojis: emojis(in: [0x1F400...0x1F43F, 0x1F980...0x1F9AE, 0x1F330...0x1F344])),
        EmojiCategorySpec(name: "Food",     symbol: "fork.knife",
                          emojis: emojis(in: [0x1F345...0x1F37F, 0x1F950...0x1F96F, 0x1F9C0...0x1F9CF])),
        EmojiCategorySpec(name: "Activities", symbol: "soccerball",
                          emojis: emojis(in: [0x1F3A0...0x1F3FF, 0x26BD...0x26BE, 0x1F94A...0x1F94F])),
        EmojiCategorySpec(name: "Travel",   symbol: "car.fill",
                          emojis: emojis(in: [0x1F680...0x1F6FF, 0x1F300...0x1F32F])),
        EmojiCategorySpec(name: "Objects",  symbol: "lightbulb.fill",
                          emojis: emojis(in: [0x1F4A0...0x1F4FF, 0x1F526...0x1F54F, 0x1F6BB...0x1F6CC])),
        EmojiCategorySpec(name: "Symbols",  symbol: "heart.fill",
                          emojis: emojis(in: [0x2600...0x26FF, 0x2700...0x27BF])),
    ]

    private static func emojis(in ranges: [ClosedRange<UInt32>]) -> [String] {
        ranges.flatMap { range -> [String] in
            range.compactMap { code -> String? in
                guard let scalar = Unicode.Scalar(code),
                      scalar.properties.isEmoji,
                      scalar.properties.isEmojiPresentation
                else { return nil }
                return String(scalar)
            }
        }
    }

    static func name(for emoji: String) -> String {
        let mutable = NSMutableString(string: emoji)
        var range = CFRange(location: 0, length: mutable.length)
        CFStringTransform(mutable, &range, "Any-Name" as CFString, false)
        return (mutable as String)
            .replacingOccurrences(of: "\\N{", with: "")
            .replacingOccurrences(of: "}", with: "")
            .lowercased()
    }
}

struct CustomEmojiPicker: View {
    let onPick: (String) -> Void

    @State private var searchText = ""
    @State private var selectedCategoryIndex = 0
    @State private var nameCache: [String: String] = [:]

    private let columns = [GridItem(.adaptive(minimum: 38, maximum: 38), spacing: 4)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search emoji…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .padding(10)

            if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                categoryTabs
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }

            Divider()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(currentEmojis, id: \.self) { emoji in
                        Button {
                            onPick(emoji)
                        } label: {
                            Text(emoji)
                                .font(.system(size: 24))
                                .frame(width: 38, height: 38)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(displayName(for: emoji))
                    }
                }
                .padding(8)
            }
        }
        .frame(width: 380, height: 420)
    }

    private var categoryTabs: some View {
        HStack(spacing: 2) {
            ForEach(EmojiCatalog.categories.indices, id: \.self) { i in
                Button {
                    selectedCategoryIndex = i
                } label: {
                    Image(systemName: EmojiCatalog.categories[i].symbol)
                        .font(.system(size: 14, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(selectedCategoryIndex == i ? Color.accentColor : Color.secondary)
                        .frame(width: 30, height: 28)
                        .background {
                            if selectedCategoryIndex == i {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15))
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(EmojiCatalog.categories[i].name)
            }
        }
    }

    private var currentEmojis: [String] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.isEmpty {
            return EmojiCatalog.categories[selectedCategoryIndex].emojis
        }
        return EmojiCatalog.categories
            .flatMap(\.emojis)
            .filter { displayName(for: $0).contains(trimmed) }
    }

    private func displayName(for emoji: String) -> String {
        if let cached = nameCache[emoji] { return cached }
        let resolved = EmojiCatalog.name(for: emoji)
        return resolved
    }
}
