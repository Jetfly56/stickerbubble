import SwiftUI
import SwiftUI

/// Browse Reddit GIF/image posts + Giphy (free API key) and pick straight into `BubbleModel`.
struct WebStickerBrowseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (URL) -> Void

    @StateObject private var state = WebStickerBrowseState()

    private let columns = [
        GridItem(.adaptive(minimum: 86, maximum: 120), spacing: 12),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: $state.provider) {
                    ForEach(WebStickerProvider.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: state.provider) { _ in state.refreshAfterProviderChange() }

                if state.provider.isGiphy {
                    HStack {
                        SecureField("Giphy API key", text: $state.apiKeyDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Save") {
                            WebStickerClient.saveGiphyAPIKey(state.apiKeyDraft)
                        }
                    }
                    Text("Free dashboard key: developers.giphy.com/dashboard/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField(state.provider.searchPlaceholder, text: $state.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { state.refresh() }

                if let status = state.status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(state.rows.isEmpty ? Color.secondary : Color.primary)
                }

                if state.isBusy {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if state.rows.isEmpty {
                    Text("Tap Load. Reddit works without keys; add a Giphy key for trending and search.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(state.rows) { item in
                                Button {
                                    onPick(item.mediaURL)
                                    dismiss()
                                } label: {
                                    WebStickerThumbnailCell(
                                        url: item.previewURL ?? item.mediaURL,
                                        title: item.title,
                                        onFailure: { state.removeRow(id: item.id) }
                                    )
                                    .aspectRatio(1, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .help(item.title)
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    if state.provider.isGiphy {
                        Link("Powered by Giphy — API terms apply", destination: URL(string: "https://developers.giphy.com/explainer/")!)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(16)
            .navigationTitle("Web stickers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Load") {
                        state.refresh()
                    }
                    .disabled(state.isBusy)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 460)
        .task {
            state.refreshInitialIfNeeded()
        }
    }
}

@MainActor
final class WebStickerBrowseState: ObservableObject {
    @Published var provider: WebStickerProvider = .redditGifs

    @Published var searchQuery = ""
    @Published var apiKeyDraft = ""

    @Published private(set) var rows: [WebStickerItem] = []
    @Published private(set) var isBusy = false
    @Published private(set) var status: String?

    func removeRow(id: String) {
        rows.removeAll { $0.id == id }
    }

    private var didInitialLoad = false

    func refreshInitialIfNeeded() {
        guard !didInitialLoad else { return }
        didInitialLoad = true
        apiKeyDraft = UserDefaults.standard.string(forKey: "ThumbDrop.giphyAPIKey") ?? ""
        refresh()
    }

    func refreshAfterProviderChange() {
        status = nil
        refresh()
    }

    func refresh() {
        if isBusy { return }
        Task { await load() }
    }

    private func load() async {
        isBusy = true
        WebStickerClient.saveGiphyAPIKey(apiKeyDraft)

        defer { isBusy = false }

        do {
            let items = try await WebStickerClient.fetch(provider: provider, searchQuery: searchQuery)
            rows = items
            if items.isEmpty {
                status = "No items — Reddit may rate-limit; try Load again later or switch to Giphy with a key."
            } else {
                status = "\(items.count) items · tap to use"
            }
        } catch let localized as LocalizedError {
            rows = []
            status = localized.errorDescription ?? localized.localizedDescription
        } catch {
            rows = []
            status = error.localizedDescription
        }
    }
}

private struct WebStickerThumbnailCell: View {
    let url: URL
    var title: String
    var onFailure: () -> Void = {}

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .empty:
                Rectangle().fill(Color.gray.opacity(0.15))
                    .overlay { ProgressView() }
            case .failure:
                Color.clear.onAppear { onFailure() }
            case .success(let image):
                image
                    .resizable()
                    .scaledToFill()
            @unknown default:
                Rectangle().fill(Color.gray.opacity(0.15))
            }
        }
        .frame(minWidth: 88, maxWidth: .infinity, minHeight: 88, maxHeight: 88)
        .accessibilityLabel(title)
    }
}
