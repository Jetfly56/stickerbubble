import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ChatBubbleView: View {
    @ObservedObject var model: BubbleModel
    var onClose: () -> Void

    @FocusState private var isEmojiFieldFocused: Bool
    @FocusState private var isCodeEditorFocused: Bool
    @State private var isCloseHovered = false
    @State private var isSettingsHovered = false
    @State private var isMuteHovered = false
    @State private var showEmojiPicker = false
    @State private var showInboxModal = false
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
                        if !model.matrixContacts.isEmpty {
                            showContactPickModal = true
                        }
                    }
                })
                .onAppear {
                    model.lastError = nil
                }
            }
            .sheet(isPresented: $showContactPickModal) {
                ContactPickModalView(model: model)
            }
            .sheet(isPresented: $showInboxModal) {
                InboxTriageModalView(model: model)
            }
            .onAppear {
                DispatchQueue.main.async {
                    isEmojiFieldFocused = true
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
                    showContactPickModal = true
                } label: {
                    Image(systemName: "person.2.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(
                            model.isSignedInToMatrix && !model.matrixContacts.isEmpty ? Color.accentColor : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .help("Choose contact…")
                .accessibilityLabel("Choose contact")
                .disabled(!model.isSignedInToMatrix || model.matrixContacts.isEmpty)
                .opacity(model.isSignedInToMatrix && !model.matrixContacts.isEmpty ? 1 : 0.45)

                Button {
                    showAddContactModal = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(model.isSignedInToMatrix ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help("Add contact…")
                .accessibilityLabel("Add contact")
                .disabled(!model.isSignedInToMatrix)
                .opacity(model.isSignedInToMatrix ? 1 : 0.45)
            }

            if !model.isSignedInToMatrix {
                Text("Sign in to Matrix via Settings (person button above, or menu). Typing here updates the preview only until you’re signed in.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.matrixContacts.isEmpty {
                Text("No Matrix contacts yet — tap person + to add someone by their MXID (e.g. @alice:matrix.org).")
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
                            ForEach(favorites, id: \.peerMxid) { c in
                                favoriteContactChip(c)
                            }
                        }
                    }
                }

                if !model.selectedPeerMxid.isEmpty {
                    let pickLabel =
                        model.matrixContacts.first { $0.peerMxid == model.selectedPeerMxid }?.displayName
                            ?? model.selectedPeerMxid
                    Text("Sending to \(pickLabel)")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let err = model.lastError, !err.isEmpty {
                Text(err)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Bottom padding for the sticker card. Drops to receive-mode size while editing,
    /// since the Send-to / emoji / send chrome is hidden in that mode.
    private var bottomPaddingForCard: CGFloat {
        if model.isReceivingMode { return 44 }
        if model.isEditingTransform { return 44 }
        return 240
    }

    /// Card uses fixed **default frame width**; GIF is laid out at 90% of that inside `StickerDisplay`.
    private var stickerCard: some View {
        Group {
            if let source = model.stickerSource {
                if isCodeBlock(source) {
                    codeBlockEditor
                        .padding(.horizontal, 12)
                        .padding(.top, 44)
                        .padding(.bottom, bottomPaddingForCard)
                } else {
                    StickerDisplay(
                        source: source,
                        expanded: $model.stickerExpanded,
                        transform: model.stickerTransform,
                        transformNonce: model.stickerTransformNonce,
                        isEditing: $model.isEditingTransform,
                        onTransformBumped: { [weak model] in model?.bumpStickerTransformNonce() }
                    )
                        .simultaneousGesture(TapGesture().onEnded {
                            isEmojiFieldFocused = false
                        })
                        .padding(.horizontal, 12)
                        .padding(.top, 44)
                        .padding(.bottom, bottomPaddingForCard)
                }
            } else {
                emptyDropZone
                    .padding(.horizontal, 12)
                    .padding(.top, 40)
                    .padding(.bottom, model.isReceivingMode ? 40 : (model.isEditingTransform ? 40 : 228))
            }
        }
        .frame(width: StickerCardLayout.defaultFrameWidth)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isCloseHovered ? Color.red : Color.secondary)
                        .font(.system(size: 18, weight: .medium))
                        .diffuseCircleBackdrop()
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .help("Hide bubble")

                Button {
                    (NSApp.delegate as? AppDelegate)?.openAccountAndSync()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "person.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(isSettingsHovered ? Color.purple : Color.secondary)
                            .font(.system(size: 18, weight: .medium))
                            .diffuseCircleBackdrop()
                    }
                }
                .buttonStyle(.plain)
                .onHover { isSettingsHovered = $0 }
                .help("Settings — Matrix account, contacts, inbox")

                Button {
                    model.globallyMuted.toggle()
                } label: {
                    let active = model.globallyMuted || isMuteHovered
                    Image(systemName: model.globallyMuted ? "bell.slash.circle.fill" : "bell.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(active ? Color(red: 0.70, green: 0.45, blue: 0.05) : Color.secondary)
                        .font(.system(size: 18, weight: .medium))
                        .diffuseCircleBackdrop()
                }
                .buttonStyle(.plain)
                .onHover { isMuteHovered = $0 }
                .help(model.globallyMuted ? "Unmute — bubble pops on new messages" : "Mute all — silence the bubble")
                .accessibilityLabel(model.globallyMuted ? "Unmute all" : "Mute all")
            }
            .padding(.leading, 10)
            .padding(.top, 10)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 6) {
                Button {
                    isChoosingFolder = true
                } label: {
                    Image(systemName: "ellipsis.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.secondary)
                        .diffuseCircleBackdrop(size: 30)
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
                        .diffuseCircleBackdrop()
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
                            .diffuseCircleBackdrop()
                    }
                    .buttonStyle(.plain)
                    .help("Open sticker grid (\(model.folderImageURLs.count))")
                    .disabled(model.folderImageURLs.isEmpty)
                }

                if canSaveCurrentSticker {
                    Button {
                        Task { await model.saveCurrentStickerToSourceFolder() }
                    } label: {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .diffuseCircleBackdrop()
                    }
                    .buttonStyle(.plain)
                    .help("Save sticker to folder")
                }

                if model.stickerSource != nil {
                    Button {
                        model.copyCurrentStickerToPasteboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .diffuseCircleBackdrop(size: 26)
                    }
                    .buttonStyle(.plain)
                    .help("Copy sticker to clipboard")
                }

                if model.isSignedInToMatrix {
                    Button {
                        showInboxModal = true
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: "tray.full")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .diffuseCircleBackdrop(size: 26)
                            if !model.inboxTriageList.isEmpty {
                                Circle()
                                    .fill(Color.red.opacity(0.95))
                                    .frame(width: 6, height: 6)
                                    .offset(x: 4, y: -2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Inbox triage — review and clear messages")
                }
            }
            .padding(.trailing, 10)
            .padding(.top, 10)
            .padding(.leading, 76)
        }
        .overlay(alignment: .bottom) {
            if !model.isReceivingMode, !model.isEditingTransform {
                VStack(alignment: .leading, spacing: 10) {
                    sendToInnerChrome

                    HStack(alignment: .center, spacing: 8) {
                        Button {
                            showEmojiPicker.toggle()
                        } label: {
                            Image(systemName: "face.smiling")
                                .font(.system(size: 22, weight: .regular))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .help("Emoji picker")
                        .accessibilityLabel("Emoji picker")
                        .popover(isPresented: $showEmojiPicker, arrowEdge: .top) {
                            CustomEmojiPicker { emoji in
                                handleEmojiPick(emoji)
                            }
                        }

                        Button {
                            toggleCodeBlockWrap()
                        } label: {
                            Text("//")
                                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Wrap text as code block")
                        .accessibilityLabel("Wrap as code block")

                        TextField(
                            "Type emoji or short text…",
                            text: Binding(
                                get: { model.emojiField },
                                set: { model.emojiField = $0 }
                            )
                        )
                        .focused($isEmojiFieldFocused)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isStickerCodeBlock)
                        .opacity(isStickerCodeBlock ? 0.5 : 1)
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
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 0.5)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay {
            if model.isReceivingMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            model.isReceivingMode = false
                        }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: model.isReceivingMode)
        .overlay(alignment: .top) {
            if let name = model.receivedFromName {
                receivedBanner(name: name)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.receivedFromName != nil)
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

    private func handleEmojiPick(_ emoji: String) {
        model.emojiField += emoji
        isEmojiFieldFocused = true
    }

    private func toggleCodeBlockWrap() {
        if case .text(let current) = model.stickerSource,
           current.hasPrefix("```"), current.hasSuffix("```")
        {
            var stripped = current
            if stripped.hasPrefix("```\n") { stripped.removeFirst(4) } else { stripped.removeFirst(3) }
            if stripped.hasSuffix("\n```") { stripped.removeLast(4) } else { stripped.removeLast(3) }
            model.unwrapStickerToField(stripped)
            DispatchQueue.main.async { isEmojiFieldFocused = true }
        } else {
            let inner = model.emojiField.trimmingCharacters(in: .whitespacesAndNewlines)
            model.setStickerTextAndClearField("```\n\(inner)\n```")
            DispatchQueue.main.async { isCodeEditorFocused = true }
        }
    }

    private func isCodeBlock(_ source: StickerSource) -> Bool {
        if case .text(let s) = source, s.hasPrefix("```"), s.hasSuffix("```") { return true }
        return false
    }

    private var isStickerCodeBlock: Bool {
        guard let s = model.stickerSource else { return false }
        return isCodeBlock(s)
    }

    private var codeBlockEditor: some View {
        TextEditor(text: codeBlockBinding)
            .focused($isCodeEditorFocused)
            .font(.system(size: 12, design: .monospaced))
            .scrollContentBackground(.hidden)
            .foregroundStyle(Color(white: 0.92))
            .padding(10)
            .frame(width: StickerCardLayout.mediaTargetWidth, height: 280)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.78))
            }
    }

    private var codeBlockBinding: Binding<String> {
        Binding(
            get: {
                guard case .text(let s) = model.stickerSource else { return "" }
                var t = s
                if t.hasPrefix("```\n") { t.removeFirst(4) } else if t.hasPrefix("```") { t.removeFirst(3) }
                if t.hasSuffix("\n```") { t.removeLast(4) } else if t.hasSuffix("```") { t.removeLast(3) }
                return t
            },
            set: { newInner in
                model.stickerSource = .text("```\n\(newInner)\n```")
            }
        )
    }

    private var canSaveCurrentSticker: Bool {
        guard model.sourceFolderURL != nil else { return false }
        switch model.stickerSource {
        case .url, .image: return true
        case .text, .none: return false
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

    private func receivedBanner(name: String) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [.accentColor.opacity(0.9), .purple.opacity(0.8)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                Text(initials(from: name))
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("From")
                    .font(.system(.caption2, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.3)
                Text(name)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func favoriteContactChip(_ c: MatrixContact) -> some View {
        let selected = model.selectedPeerMxid == c.peerMxid
        Button {
            model.selectedPeerMxid = c.peerMxid
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

extension View {
    func diffuseCircleBackdrop(size: CGFloat = 28) -> some View {
        background {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: size, height: size)
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Add Matrix contact modal

private struct AddContactModalView: View {
    @ObservedObject var model: BubbleModel
    var onAddedSuccessfully: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var peerMxid = ""
    @State private var isAdding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("@alice:matrix.org", text: $peerMxid)
                        .font(.system(.body, design: .monospaced))
                    TextField("Display name (optional)", text: $displayName)
                } footer: {
                    Text("ThumbDrop finds an existing 1-1 DM with this peer, or creates a new private invite-only room and invites them. They’ll see the invite in their Matrix client and accept to join.")
                        .font(.caption)
                }
                if let err = model.lastError, !err.isEmpty {
                    Section {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Matrix contact")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task {
                            isAdding = true
                            let target = peerMxid.trimmingCharacters(in: .whitespacesAndNewlines)
                            await model.addMatrixContact(peerMxid: peerMxid, displayName: displayName)
                            isAdding = false
                            if model.matrixContacts.contains(where: { $0.peerMxid == target }) {
                                displayName = ""
                                peerMxid = ""
                                let notify = onAddedSuccessfully
                                dismiss()
                                DispatchQueue.main.async { notify?() }
                            }
                        }
                    }
                    .disabled(peerMxid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
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
                if model.matrixContacts.isEmpty {
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
                        ForEach(model.matrixContacts) { c in
                            HStack(alignment: .center, spacing: 12) {
                                Button {
                                    model.selectedPeerMxid = c.peerMxid
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.displayName)
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        Text(c.peerMxid)
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
                                    model.toggleMutePeer(c.peerMxid)
                                } label: {
                                    Image(systemName: model.isPeerMuted(c.peerMxid) ? "bell.slash.fill" : "bell")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundStyle(model.isPeerMuted(c.peerMxid) ? Color.orange : Color.secondary)
                                        .accessibilityLabel(model.isPeerMuted(c.peerMxid) ? "Unmute" : "Mute")
                                }
                                .buttonStyle(.plain)
                                .help(model.isPeerMuted(c.peerMxid) ? "Unmute — bubble pops when they send" : "Mute — incoming messages won't pop the bubble")

                                Button {
                                    model.toggleFavoritePeer(mxid: c.peerMxid)
                                } label: {
                                    Image(systemName: model.isFavoritePeer(c.peerMxid) ? "star.fill" : "star")
                                        .font(.system(size: 18, weight: .medium))
                                        .foregroundStyle(model.isFavoritePeer(c.peerMxid) ? Color.yellow : Color.secondary)
                                        .accessibilityLabel(model.isFavoritePeer(c.peerMxid) ? "Remove favorite" : "Add favorite")
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
                    Button("Done") { dismiss() }
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

// MARK: - Inbox triage modal

struct InboxTriageModalView: View {
    @ObservedObject var model: BubbleModel
    @Environment(\.dismiss) private var dismiss
    @State private var isRefreshing = false
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Group {
                    if model.inboxTriageList.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "tray")
                                .font(.system(size: 44, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Inbox is empty")
                                .font(.headline)
                            if isRefreshing {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("New messages will show up here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        List {
                            ForEach(model.inboxTriageList, id: \.id) { msg in
                                InboxTriageRow(model: model, msg: msg) {
                                    model.loadInboxMessageIntoBubble(msg)
                                    dismiss()
                                }
                            }
                            .onDelete(perform: deleteAt)
                        }
                    }
                }

                Divider()

                HStack(spacing: 10) {
                    Button {
                        Task {
                            isRefreshing = true
                            await model.refreshInboxTriage()
                            isRefreshing = false
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isRefreshing)

                    Spacer()

                    if let err = model.lastError, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear all", systemImage: "trash")
                    }
                    .disabled(model.inboxTriageList.isEmpty)
                }
                .padding(12)
            }
            .navigationTitle("Inbox")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear every message in your inbox?",
                isPresented: $showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("Clear inbox", role: .destructive) {
                    Task { await model.clearInbox() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes them from this Mac. New messages from peers will still arrive normally.")
            }
            .task {
                if model.inboxTriageList.isEmpty {
                    isRefreshing = true
                    await model.refreshInboxTriage()
                    isRefreshing = false
                }
            }
        }
        .frame(minWidth: 460, minHeight: 480)
    }

    private func deleteAt(_ offsets: IndexSet) {
        let targets = offsets.map { model.inboxTriageList[$0] }
        Task {
            for msg in targets {
                await model.deleteInboxMessage(msg)
            }
        }
    }
}

private struct InboxTriageRow: View {
    @ObservedObject var model: BubbleModel
    let msg: InboxMessage
    let onView: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            preview
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderLabel)
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .lineLimit(1)
                    Text(msg.senderUserId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let body = msg.body, !body.isEmpty {
                    Text(body)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                Button {
                    onView()
                } label: {
                    Image(systemName: "eye")
                }
                .buttonStyle(.borderless)
                .help("Open in bubble")

                Button(role: .destructive) {
                    Task { await model.deleteInboxMessage(msg) }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete")
            }
        }
        .padding(.vertical, 4)
    }

    private var senderLabel: String {
        let name = msg.senderDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? msg.senderUserId : name
    }

    @ViewBuilder
    private var preview: some View {
        if let s = msg.stickerUrl, !s.isEmpty {
            if s.hasPrefix("data:") {
                if let img = inboxImage(fromDataURL: s) {
                    Image(nsImage: img).resizable().scaledToFill()
                } else {
                    placeholder("photo")
                }
            } else if let url = URL(string: s) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty: placeholder("photo")
                    case .success(let image): image.resizable().scaledToFill()
                    case .failure: placeholder("link")
                    @unknown default: placeholder("photo")
                    }
                }
            } else {
                placeholder("link")
            }
        } else if let body = msg.body, !body.isEmpty {
            ZStack {
                Color.accentColor.opacity(0.18)
                Text(String(body.prefix(2)))
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            placeholder("envelope")
        }
    }

    private func placeholder(_ symbol: String) -> some View {
        ZStack {
            Color.gray.opacity(0.18)
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func inboxImage(fromDataURL raw: String) -> NSImage? {
        guard let comma = raw.firstIndex(of: ",") else { return nil }
        let encoded = String(raw[raw.index(after: comma)...])
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return NSImage(data: data)
    }
}

