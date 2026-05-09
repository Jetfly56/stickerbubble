import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatBubbleView: View {
    @ObservedObject var model: BubbleModel
    var onClose: () -> Void

    @FocusState private var isEmojiFieldFocused: Bool
    @State private var isChoosingFolder = false
    @State private var showGridPicker = false
    @State private var showWebStickerSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            stickerCard
            railwaySection
            emojiSendSection
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    model.setSourceFolder(url)
                }
            case .failure:
                break
            }
        }
        .sheet(isPresented: $showWebStickerSheet) {
            WebStickerBrowseSheet { url in
                model.loadSticker(url: url)
            }
        }
        .sheet(isPresented: $showGridPicker) {
            StickerGridPickerView(
                urls: model.folderImageURLs,
                folderLabel: model.sourceFolderURL?.lastPathComponent,
                onPick: { url in
                    model.loadSticker(url: url)
                    showGridPicker = false
                },
                onRescan: { model.refreshFolderListing() }
            )
        }
        .onAppear {
            DispatchQueue.main.async {
                isEmojiFieldFocused = true
            }
            Task {
                if model.isSignedIn {
                    await model.refreshRemoteContacts()
                }
            }
        }
    }

    private var railwaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Railway")
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)

            if !model.isSignedIn {
                Text("Sign in under Account & sync… to send stickers to your contacts’ user IDs.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
            } else if model.remoteContacts.isEmpty {
                Text(
                    model.railwayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Set your server URL in Account & sync…, then add contacts by their user ID."
                        : "No contacts yet — open Account & sync… and add people by user ID, then Refresh contacts."
                )
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
            } else {
                Picker("Server recipient", selection: $model.selectedPeerUserId) {
                    Text("— choose —").tag("")
                    ForEach(model.remoteContacts) { c in
                        Text(c.displayName).tag(c.peerUserId)
                    }
                }
                .labelsHidden()
            }

            HStack(spacing: 10) {
                Button("Send (server)") {
                    Task { await model.sendCurrentStickerToRailway() }
                }
                .disabled(!model.isSignedIn || model.selectedPeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Refresh contacts") {
                    Task { await model.refreshRemoteContacts() }
                }

                Button("Account & sync…") {
                    (NSApp.delegate as? AppDelegate)?.openAccountAndSync()
                }
            }

            if let err = model.lastRailwayError, !err.isEmpty {
                Text(err)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.red)
            }
        }
    }

    /// Card uses fixed **default frame width**; GIF is laid out at 90% of that inside `StickerDisplay`.
    private var stickerCard: some View {
        Group {
            if let source = model.stickerSource {
                StickerDisplay(source: source)
                    .padding(.horizontal, 12)
                    .padding(.top, 44)
                    .padding(.bottom, 128)
            } else {
                emptyDropZone
                    .padding(.horizontal, 12)
                    .padding(.top, 40)
                    .padding(.bottom, 112)
            }
        }
        .frame(width: StickerCardLayout.defaultFrameWidth)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Button {
                    isChoosingFolder = true
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Choose sticker folder")
                .contextMenu {
                    Button("Choose folder…") {
                        isChoosingFolder = true
                    }
                    Divider()
                    Button("Rescan folder") {
                        model.refreshFolderListing()
                    }
                    .disabled(model.sourceFolderURL == nil)
                    Button("Remove folder", role: .destructive) {
                        model.clearSourceFolder()
                    }
                    .disabled(model.sourceFolderURL == nil)
                }

                Button {
                    showWebStickerSheet = true
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Web stickers · Reddit / Giphy")

                if model.sourceFolderURL != nil {
                    Button {
                        showGridPicker = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open sticker grid (\(model.folderImageURLs.count))")
                    .disabled(model.folderImageURLs.isEmpty)
                }
            }
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.trailing, 44)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18, weight: .medium))
            }
            .buttonStyle(.plain)
            .padding(.trailing, 10)
            .padding(.top, 10)
            .help("Hide bubble")
        }
        .overlay(alignment: .bottomLeading) {
            recipientSection
                .frame(maxWidth: 300, alignment: .leading)
                .padding(12)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.regularMaterial.opacity(0.92))
                        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                }
                .padding(.leading, 12)
                .padding(.bottom, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var emojiSendSection: some View {
        HStack(alignment: .center, spacing: 10) {
            TextField("Type emoji or short text…", text: Binding(
                get: { model.emojiField },
                set: { model.emojiField = $0 }
            ))
            .focused($isEmojiFieldFocused)
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                model.sendEmojiFromInput()
            }

            Button("Send") {
                model.sendEmojiFromInput()
            }
        }
    }

    /// Draft recipient chip anchored **inside** sticker frame bottom-leading.
    private var recipientSection: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.85), .purple.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(initials(from: model.recipientName))
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 36, height: 36)
            .accessibilityLabel("Recipient initials")

            VStack(alignment: .leading, spacing: 4) {
                Text("Recipient")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.35)

                TextField("Name", text: Binding(
                    get: { model.recipientName },
                    set: { model.recipientName = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))

                TextField("Optional note", text: Binding(
                    get: { model.recipientDetail },
                    set: { model.recipientDetail = $0 }
                ))
                .textFieldStyle(.plain)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)

                Text("Preview only — not delivered.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a sticker or image")
                .font(.system(.body, design: .rounded, weight: .medium))
            Text("⋯ · web · grid • type below • ⌘⇧V image paste")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, minHeight: 160)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                accepted = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    Task { @MainActor in
                        model.loadSticker(url: url)
                    }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                    guard let image = image as? NSImage else { return }
                    Task { @MainActor in
                        model.loadSticker(image: image)
                    }
                }
            }
        }
        return accepted
    }

    private func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ").map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }
}

// MARK: - Grid sheet

private struct StickerGridPickerView: View {
    let urls: [URL]
    var folderLabel: String?
    var onPick: (URL) -> Void
    var onRescan: () -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 76, maximum: 112), spacing: 10),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if urls.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No stickers")
                            .font(.headline)
                        Text("Rescan the folder or pick another from ⋯ in the bubble.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 280)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(urls, id: \.self) { url in
                                Button {
                                    onPick(url)
                                } label: {
                                    StickerThumbnail(url: url)
                                        .frame(width: 88, height: 88)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle(folderLabel ?? "Stickers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        onRescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan folder")
                }
            }
        }
        .frame(minWidth: 420, minHeight: 420)
    }
}

private struct StickerThumbnail: View {
    let url: URL

    var body: some View {
        Group {
            if let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.gray.opacity(0.2)
            }
        }
    }
}
