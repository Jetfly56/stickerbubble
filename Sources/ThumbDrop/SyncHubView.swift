import AppKit
import Combine
import SwiftUI

/// Account & sync settings: Matrix homeserver, sign-in, contacts, inbox.
struct SyncHubView: View {
    @ObservedObject var model: BubbleModel

    @State private var matrixHomeserverDraft = ""
    @State private var matrixUsername = ""
    @State private var matrixPassword = ""
    @State private var matrixAccessTokenDraft = ""
    @State private var matrixUseAccessToken = false
    @State private var newMatrixPeerMxid = ""
    @State private var newMatrixContactName = ""
    @State private var beeperDesktopAccounts: [BeeperLocalAuth.Account] = []
    @State private var beeperDetectStatus: String?
    @State private var beeperShowManualFallback: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.isSignedInToMatrix {
                    Text("Sign in to a Matrix homeserver — matrix.org for plain Matrix, or matrix.beeper.com for Beeper accounts. iOS clients (Element, Element X, FluffyChat, Beeper) signed in to the same account share the same conversations.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                matrixSection

                if model.isSignedInToMatrix {
                    contactsSection
                    inboxSection
                }

                if let err = model.lastError, !err.isEmpty {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 440, minHeight: 560)
        .onAppear {
            matrixHomeserverDraft = model.matrixHomeserverURL
        }
    }

    private var matrixSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Matrix")
            Text("Unencrypted rooms only — Matrix-to-Matrix DMs. End-to-end encryption is not yet supported.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.isSignedInToMatrix {
                Text("Homeserver")
                    .font(.subheadline.weight(.semibold))
                TextField("https://matrix.org", text: $matrixHomeserverDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                HStack(spacing: 8) {
                    Button("matrix.org") {
                        matrixHomeserverDraft = MatrixClient.defaultHomeserverURL
                        model.setMatrixHomeserverURL(matrixHomeserverDraft)
                        matrixUseAccessToken = false
                    }
                    Button("Beeper (matrix.beeper.com)") {
                        matrixHomeserverDraft = MatrixClient.beeperHomeserverURL
                        model.setMatrixHomeserverURL(matrixHomeserverDraft)
                        matrixUseAccessToken = true
                    }
                    Spacer()
                    Button("Save") {
                        model.setMatrixHomeserverURL(matrixHomeserverDraft)
                    }
                }
                .font(.caption)

                let isBeeper = matrixHomeserverDraft.contains("beeper.com")

                createAccountRow(isBeeper: isBeeper)

                if isBeeper {
                    Text("Sign in by reading your existing Beeper Desktop login. Beeper itself doesn't expose a public auth API, but its CLI (`bbctl`) reads from `~/Library/Application Support/BeeperTexts/account.db` — we use the same path.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)

                    beeperDesktopSignInPanel

                    DisclosureGroup(isExpanded: $beeperShowManualFallback) {
                        beeperManualFallback
                    } label: {
                        Text("No Beeper Desktop? Paste a token instead")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                } else {
                    Picker("", selection: $matrixUseAccessToken) {
                        Text("Username & password").tag(false)
                        Text("Paste access token").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(.top, 4)

                    if matrixUseAccessToken {
                        Text("Paste a Matrix access token from another client. Useful for self-hosted homeservers with custom auth flows.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        SecureField("Access token", text: $matrixAccessTokenDraft)
                            .textFieldStyle(.roundedBorder)
                        Button("Sign in with access token") {
                            Task {
                                model.setMatrixHomeserverURL(matrixHomeserverDraft)
                                await model.signInToMatrixWithAccessToken(matrixAccessTokenDraft)
                                if model.isSignedInToMatrix {
                                    matrixAccessTokenDraft = ""
                                }
                            }
                        }
                        .disabled(matrixAccessTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } else {
                        TextField("Username (the localpart, without @ or :server)", text: $matrixUsername)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        SecureField("Password", text: $matrixPassword)
                            .textFieldStyle(.roundedBorder)
                        Button("Sign in") {
                            Task {
                                model.setMatrixHomeserverURL(matrixHomeserverDraft)
                                await model.signInToMatrix(username: matrixUsername, password: matrixPassword)
                                if model.isSignedInToMatrix {
                                    matrixPassword = ""
                                }
                            }
                        }
                        .disabled(matrixUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || matrixPassword.isEmpty)
                    }
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Homeserver")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(model.matrixHomeserverURL)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Signed in as")
                        .font(.body)
                    Text(model.matrixUserId)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                Button("Sign out of Matrix") {
                    model.signOutFromMatrix()
                }
            }
        }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Matrix contacts")
            Text("Add someone by their Matrix ID. ThumbDrop finds an existing 1-1 DM with them, or creates a private invite-only room and invites them. Stickers between you flow through that room.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.matrixContacts.contains(where: { $0.peerMxid == model.matrixUserId }) {
                HStack {
                    Button("Add \"Me\" (Notes to self)") {
                        Task { await model.addSelfMatrixContact() }
                    }
                    Text("Creates a private room you're alone in — useful for testing, or syncing notes between your iOS Matrix client and this Mac.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(alignment: .top, spacing: 10) {
                TextField("Name (optional)", text: $newMatrixContactName)
                    .textFieldStyle(.roundedBorder)
                TextField("@alice:matrix.org", text: $newMatrixPeerMxid)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button("Add Matrix contact") {
                Task {
                    let peerToAdd = newMatrixPeerMxid.trimmingCharacters(in: .whitespacesAndNewlines)
                    await model.addMatrixContact(peerMxid: newMatrixPeerMxid, displayName: newMatrixContactName)
                    if model.matrixContacts.contains(where: { $0.peerMxid == peerToAdd }) {
                        newMatrixPeerMxid = ""
                        newMatrixContactName = ""
                    }
                }
            }
            .disabled(newMatrixPeerMxid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if model.matrixContacts.isEmpty {
                Text("No Matrix contacts yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.matrixContacts) { contact in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(contact.displayName)
                                .font(.body)
                            Text(contact.peerMxid)
                                .font(.caption2)
                                .monospaced()
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        if model.selectedPeerMxid == contact.peerMxid {
                            Text("Selected")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.green)
                        } else {
                            Button("Use") {
                                model.selectedPeerMxid = contact.peerMxid
                            }
                        }
                        Button("Remove", role: .destructive) {
                            model.deleteMatrixContact(peerMxid: contact.peerMxid)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Inbox")
            Button("Refresh inbox") {
                Task { await model.refreshInboxTriage() }
            }
            if model.inboxTriageList.isEmpty {
                Text("No messages yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.inboxTriageList, id: \.id) { msg in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("from")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(inboxSenderPrimaryLabel(msg))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                if inboxSenderShowsUserId(msg) {
                                    Text(msg.senderUserId)
                                        .font(.caption2)
                                        .monospaced()
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                        }
                        if let b = msg.body, !b.isEmpty {
                            Text(b).font(.caption).lineLimit(2)
                        }
                        if let s = msg.stickerUrl, !s.isEmpty {
                            Text(s.hasPrefix("data:") ? "Image attachment" : s)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        HStack(spacing: 10) {
                            Button("Show in bubble") {
                                model.loadInboxMessageIntoBubble(msg)
                            }
                            Button("Reply") {
                                model.replyToMatrixInboxMessage(msg)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func createAccountRow(isBeeper: Bool) -> some View {
        HStack(spacing: 6) {
            Text("No account?")
                .font(.caption2)
                .foregroundStyle(.secondary)
            if isBeeper {
                Button("Sign up at beeper.com") {
                    if let url = URL(string: "https://www.beeper.com/") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2)
                Text("then sign in to Beeper Desktop and tap Detect below.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Create on Element Web") {
                    if let url = URL(string: "https://app.element.io/#/register") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.caption2)
                Text("then come back here and sign in.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var beeperDesktopSignInPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Detect Beeper Desktop") {
                    beeperDetectStatus = nil
                    let accounts = BeeperLocalAuth.discoverAccounts()
                    beeperDesktopAccounts = accounts
                    if accounts.isEmpty {
                        beeperDetectStatus = "No Beeper Desktop install found at ~/Library/Application Support/BeeperTexts/account.db. Install Beeper Desktop and sign in there first, or paste a token below."
                    }
                }
                Spacer()
            }

            if let s = beeperDetectStatus, !s.isEmpty {
                Text(s)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(Array(beeperDesktopAccounts.enumerated()), id: \.offset) { _, account in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.userId)
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        Text(account.sourcePath.path)
                            .font(.caption2)
                            .monospaced()
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Sign in") {
                        Task {
                            await model.signInToBeeperFromDesktop(account)
                            if model.isSignedInToMatrix {
                                beeperDesktopAccounts = []
                                beeperDetectStatus = nil
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var beeperManualFallback: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Paste a Matrix access token (from `bbctl login` or another Beeper client).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Access token", text: $matrixAccessTokenDraft)
                .textFieldStyle(.roundedBorder)
            Button("Sign in with access token") {
                Task {
                    model.setMatrixHomeserverURL(matrixHomeserverDraft)
                    await model.signInToMatrixWithAccessToken(matrixAccessTokenDraft)
                    if model.isSignedInToMatrix {
                        matrixAccessTokenDraft = ""
                    }
                }
            }
            .disabled(matrixAccessTokenDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.title3.weight(.semibold))
    }

    private func inboxSenderPrimaryLabel(_ msg: InboxMessage) -> String {
        if let n = msg.senderDisplayName {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return msg.senderUserId
    }

    private func inboxSenderShowsUserId(_ msg: InboxMessage) -> Bool {
        guard let n = msg.senderDisplayName else { return false }
        return !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
