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
    @State private var showAddContactModal = false
    @State private var showContactPickModal = false

    var body: some View {
        stickerCard
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
            .sheet(isPresented: $showAddContactModal) {
                AddContactModalView(model: model, onAddedSuccessfully: {
                    Task { @MainActor in
                        await model.refreshRemoteContacts()
                        await model.refreshContactRequests()
                        if !model.remoteContacts.isEmpty {
                            showContactPickModal = true
                        }
                    }
                })
                .onAppear {
                    model.lastRailwayError = nil
                }
            }
            .sheet(isPresented: $showContactPickModal) {
                ContactPickModalView(model: model)
            }
            .onAppear {
                DispatchQueue.main.async {
                    isEmojiFieldFocused = true
                }
                Task {
                    if model.isSignedIn {
                        await model.refreshRemoteContacts()
                        await model.refreshContactRequests()
                    }
                }
            }
    }

    /// Send-to messaging + picker + errors (inside sticker frame).
    private var sendToInnerChrome: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Text("Send to")
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                Spacer(minLength: 4)
                Button {
                    refreshContactsThenOpenPicker()
                } label: {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            model.isSignedIn && !model.remoteContacts.isEmpty ? Color.accentColor : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .help("Choose contact…")
                .accessibilityLabel("Choose contact")
                .disabled(!model.isSignedIn || model.remoteContacts.isEmpty)
                .opacity(model.isSignedIn && !model.remoteContacts.isEmpty ? 1 : 0.45)

                Button {
                    showAddContactModal = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.isSignedIn ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Add contact…")
                .accessibilityLabel("Add contact")
                .disabled(!model.isSignedIn)
                .opacity(model.isSignedIn ? 1 : 0.45)
            }

            if !model.isSignedIn {
                Text("Sign in via Settings (person button above, or menu). Typing here updates the preview only until you’re signed in.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.remoteContacts.isEmpty {
                Text(
                    model.railwayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? "Open Settings and set your server URL, then add contacts by user ID."
                        : (model.incomingContactRequests.isEmpty && model.outgoingContactRequests.isEmpty
                            ? "No contacts yet — tap person + beside Send to (or use Settings) to invite someone by user ID."
                            : "No accepted contacts yet — open Settings (person icon) to accept an invite or see outgoing requests.")
                )
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                let favorites = model.favoriteContactsForBubbleBar()
                if favorites.isEmpty {
                    Text("Open Contacts (two-person icon) and tap the star on someone to pin them here for quick send.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(favorites, id: \.peerUserId) { c in
                                favoriteContactChip(c)
                            }
                        }
                    }
                }

                if !model.selectedPeerUserId.isEmpty {
                    let pickLabel =
                        model.remoteContacts.first { $0.peerUserId == model.selectedPeerUserId }?.displayName
                            ?? model.selectedPeerUserId
                    Text("Sending to \(pickLabel)")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Text("Tap the blue send button to deliver.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            if let err = model.lastRailwayError, !err.isEmpty {
                Text(err)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let note = model.contactInviteNotice, !note.isEmpty, model.isSignedIn {
                Text(note)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
                    .padding(.bottom, 318)
            } else {
                emptyDropZone
                    .padding(.horizontal, 12)
                    .padding(.top, 40)
                    .padding(.bottom, 306)
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
            .padding(.trailing, 76)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button {
                    (NSApp.delegate as? AppDelegate)?.openAccountAndSync()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 18, weight: .medium))
                        if !model.incomingContactRequests.isEmpty {
                            Circle()
                                .fill(Color.red.opacity(0.95))
                                .frame(width: 7, height: 7)
                                .offset(x: 3, y: -2)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("Settings — account, server, contacts, inbox")

                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                        .font(.system(size: 18, weight: .medium))
                }
                .buttonStyle(.plain)
                .help("Hide bubble")
            }
            .padding(.trailing, 10)
            .padding(.top, 10)
        }
        .overlay(alignment: .bottomLeading) {
            VStack(alignment: .leading, spacing: 10) {
                sendToInnerChrome

                HStack(alignment: .center, spacing: 8) {
                    TextField("Type emoji or short text…", text: Binding(
                        get: { model.emojiField },
                        set: { model.emojiField = $0 }
                    ))
                    .focused($isEmojiFieldFocused)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        Task { await model.performSend() }
                    }

                    Button {
                        Task { await model.performSend() }
                    } label: {
                        Image(systemName: "paperplane.circle.fill")
                            .font(.system(size: 28, weight: .regular))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Send — sticker or text goes to the contact chosen in Send to when signed in; otherwise updates the preview.")
                    .accessibilityLabel("Send")
                }

                Text("Preview only — not delivered.")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .padding(.bottom, 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var emptyDropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a sticker or image")
                .font(.system(.body, design: .rounded, weight: .medium))
            Text("⋯ · web · grid • type in panel • ⌘⇧V image paste")
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

    /// Latest server list before showing the contact picker (Contacts button or after add).
    private func refreshContactsThenOpenPicker() {
        Task {
            await model.refreshRemoteContacts()
            showContactPickModal = true
        }
    }

    private func initials(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ").map(String.init)
        let letters = parts.prefix(2).compactMap { $0.first }
        let s = String(letters).uppercased()
        return s.isEmpty ? "?" : s
    }

    @ViewBuilder
    private func favoriteContactChip(_ c: RailwayRemoteContact) -> some View {
        let selected = model.selectedPeerUserId == c.peerUserId
        Button {
            model.selectedPeerUserId = c.peerUserId
        } label: {
            Text(c.displayName)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background {
                    Capsule()
                        .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06))
                }
                .overlay {
                    Capsule()
                        .strokeBorder(selected ? Color.accentColor.opacity(0.9) : Color.clear, lineWidth: 1.5)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add contact modal

private struct AddContactModalView: View {
    @ObservedObject var model: BubbleModel
    var onAddedSuccessfully: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var peerUserId = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Their user ID", text: $peerUserId)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: peerUserId) { newVal in
                            model.scheduleAddContactUserIdLookup(draftRaw: newVal)
                        }
                    TextField("Display name (optional)", text: $displayName)
                    AddContactPeerLookupBanner(state: model.addContactPeerLookup)
                } footer: {
                    Text(
                        "This sends them a contact invite — they must accept in Settings before you can choose them to send stickers. Leave name empty to infer from their latest message, when possible."
                    )
                    .font(.caption)
                }
                if let err = model.lastRailwayError, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add contact")
            .onAppear {
                model.scheduleAddContactUserIdLookup(draftRaw: peerUserId)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.clearAddContactUserIdLookup()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            isAdding = true
                            await model.addRemoteContact(displayName: displayName, peerUserId: peerUserId)
                            isAdding = false
                            if let err = model.lastRailwayError, !err.isEmpty {
                                return
                            }
                            model.clearAddContactUserIdLookup()
                            displayName = ""
                            peerUserId = ""
                            let notify = onAddedSuccessfully
                            dismiss()
                            DispatchQueue.main.async {
                                notify?()
                            }
                        }
                    }
                    .disabled(peerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 260)
    }
}

// MARK: - Contact pick modal

private struct ContactPickModalView: View {
    @ObservedObject var model: BubbleModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.remoteContacts.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("No contacts")
                            .font(.headline)
                        Text("Use Add contact from the bubble or Settings.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(model.remoteContacts) { c in
                            HStack(alignment: .center, spacing: 12) {
                                Button {
                                    model.selectedPeerUserId = c.peerUserId
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.displayName)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(c.peerUserId)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospaced()
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.toggleFavoritePeer(peerUserId: c.peerUserId)
                                } label: {
                                    Image(systemName: model.isFavoritePeer(c.peerUserId) ? "star.fill" : "star")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(model.isFavoritePeer(c.peerUserId) ? Color.yellow : Color.secondary)
                                        .accessibilityLabel(model.isFavoritePeer(c.peerUserId) ? "Remove favorite" : "Add favorite")
                                }
                                .buttonStyle(.plain)
                                .help("Favorite — shows as a chip on the bubble")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Contacts")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 380)
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
