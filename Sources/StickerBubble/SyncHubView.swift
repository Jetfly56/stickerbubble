import AppKit
import Combine
import SwiftUI

/// Server URL, sign-in / register, recovery (code from a signed-in device only), contacts, inbox.
struct SyncHubView: View {
    @ObservedObject var model: BubbleModel

    @State private var serverURLDraft = ""
    @State private var signInUserId = ""
    @State private var signInPassword = ""
    @State private var registerConfirmPassword = ""

    @State private var recoverUserId = ""
    @State private var recoverCode = ""
    @State private var recoverNewPassword = ""

    @State private var changeOldPassword = ""
    @State private var changeNewPassword = ""

    @State private var newContactName = ""
    @State private var newPeerUserId = ""

    @State private var recoveryCodeShown: String?
    @State private var recoveryExpires: String?
    @State private var recoveryError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.isSignedIn {
                    Text("Accounts use a user ID you share with friends. Each Mac has its own device token; sign in on every machine with the same user ID and password.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                serverSection

                if model.isSignedIn {
                    signedInSection
                } else {
                    signInRegisterSection
                    recoverySection
                }

                if model.isSignedIn {
                    contactsSection
                    inboxSection
                }

                optionalWebSection

                if let err = model.lastRailwayError, !err.isEmpty {
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
            serverURLDraft = model.railwayBaseURL
            signInUserId = model.signedInUserId
            Task {
                if model.isSignedIn {
                    await model.refreshRemoteContacts()
                    await model.refreshInboxTriage()
                }
            }
        }
        .alert("Recovery code", isPresented: Binding(
            get: { recoveryCodeShown != nil },
            set: { if !$0 { recoveryCodeShown = nil; recoveryExpires = nil } }
        )) {
            Button("Copy code") {
                if let c = recoveryCodeShown {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c, forType: .string)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            if let c = recoveryCodeShown, let e = recoveryExpires {
                Text("Give this code to your other Mac (or keep it private). It expires around \(e).\n\n\(c)")
            }
        }
    }

    private var serverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Server")
            TextField("https://your-app.up.railway.app", text: $serverURLDraft)
                .textFieldStyle(.roundedBorder)
            Button("Save & connect") {
                model.setRailwayBaseURL(serverURLDraft)
                Task {
                    if model.isSignedIn {
                        await model.refreshRemoteContacts()
                        await model.refreshInboxTriage()
                    }
                }
            }
        }
    }

    private var signInRegisterSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Sign in")
            Text("Server needs JWT_SECRET set (32+ random chars). Add it in Railway variables if deploy fails.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            TextField("User ID", text: $signInUserId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            SecureField("Password (8+ characters)", text: $signInPassword)
                .textFieldStyle(.roundedBorder)

            HStack(spacing: 10) {
                Button("Sign in") {
                    Task {
                        await model.signIn(userId: signInUserId, password: signInPassword)
                        if model.isSignedIn {
                            signInPassword = ""
                            registerConfirmPassword = ""
                        }
                    }
                }
                .disabled(signInUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || signInPassword.count < 8)
            }

            Divider().padding(.vertical, 4)

            sectionTitle("Create account")
            Text(
                "You are creating an account on this server only. Your user ID can be seen by people you share it with; your password is stored as a hash and never sent in plain text after this. You cannot recover your password by email—use a recovery code from another signed-in Mac if you forget it."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Text("New here? Enter the same user ID and password as above, confirm the password, then create your account.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            SecureField("Confirm password", text: $registerConfirmPassword)
                .textFieldStyle(.roundedBorder)

            if !registerConfirmPassword.isEmpty, signInPassword != registerConfirmPassword {
                Text("Passwords do not match.")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            TextField("Display name (optional, profile + sent with stickers)", text: $model.localDisplayName)
                .textFieldStyle(.roundedBorder)

            Button("Create account") {
                Task {
                    await model.register(userId: signInUserId, password: signInPassword)
                    if model.isSignedIn {
                        signInPassword = ""
                        registerConfirmPassword = ""
                    }
                }
            }
            .disabled(
                signInUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || signInPassword.count < 8
                    || signInPassword != registerConfirmPassword
            )
        }
    }

    private var recoverySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Forgot password on this Mac?")
            Text(
                "Password reset is not done by email. On a Mac where you are already signed in, open Account & sync and tap Generate recovery code, then enter that code here with a new password."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            TextField("Your user ID", text: $recoverUserId)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            TextField("Recovery code", text: $recoverCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
            SecureField("New password (8+)", text: $recoverNewPassword)
                .textFieldStyle(.roundedBorder)

            Button("Complete recovery & sign in on this Mac") {
                Task {
                    await model.recoverAccount(userId: recoverUserId, code: recoverCode, newPassword: recoverNewPassword)
                    if model.isSignedIn {
                        recoverCode = ""
                        recoverNewPassword = ""
                    }
                }
            }
            .disabled(
                recoverUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || recoverCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || recoverNewPassword.count < 8
            )
        }
    }

    private var signedInSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Signed in")
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Signed in as")
                    .font(.body)
                Text(model.signedInUserId)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .textSelection(.enabled)
            }
            Text("User ID and password fields are hidden while you are signed in. Sign out to use a different account on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Sign out on this Mac") {
                model.signOut()
            }

            TextField("Display name (profile + sent with stickers)", text: $model.localDisplayName)
                .textFieldStyle(.roundedBorder)
            Button("Save display name") {
                model.saveLocalDisplayName()
            }

            Divider()

            sectionTitle("Change password")
            SecureField("Current password", text: $changeOldPassword)
                .textFieldStyle(.roundedBorder)
            SecureField("New password (8+)", text: $changeNewPassword)
                .textFieldStyle(.roundedBorder)
            Button("Update password") {
                Task {
                    await model.changePassword(oldPassword: changeOldPassword, newPassword: changeNewPassword)
                    if model.lastRailwayError == nil {
                        changeOldPassword = ""
                        changeNewPassword = ""
                    }
                }
            }
            .disabled(changeOldPassword.isEmpty || changeNewPassword.count < 8)

            Divider()

            sectionTitle("Recovery for another device")
            Text("Generate a one-time code (valid ~20 minutes). Use it on the other Mac in the section above. Anyone with the code can set a new password for your account—treat it like a secret.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recoveryError, !recoveryError.isEmpty {
                Text(recoveryError).font(.caption).foregroundStyle(.red)
            }
            Button("Generate recovery code") {
                Task {
                    recoveryError = nil
                    do {
                        let pair = try await model.createRecoveryCode()
                        recoveryCodeShown = pair.code
                        recoveryExpires = pair.expiresAt
                    } catch {
                        recoveryError = error.localizedDescription
                    }
                }
            }
        }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Contacts")
            Text("Add people by their user ID. Leave name empty to infer from their latest message display name, or use their user ID as the label.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 10) {
                TextField("Name (optional)", text: $newContactName)
                    .textFieldStyle(.roundedBorder)
                TextField("Their user ID", text: $newPeerUserId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button("Add contact") {
                Task {
                    await model.addRemoteContact(displayName: newContactName, peerUserId: newPeerUserId)
                    newContactName = ""
                    newPeerUserId = ""
                }
            }
            .disabled(newPeerUserId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if model.remoteContacts.isEmpty {
                Text("No contacts yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.remoteContacts) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).font(.headline)
                            Text(c.peerUserId).font(.caption).monospaced().foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            Task { await model.deleteRemoteContact(id: c.id) }
                        }
                    }
                    .padding(.vertical, 6)
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
                            Text("#\(msg.id)")
                                .font(.caption.weight(.semibold))
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
                        Button("Show in bubble") {
                            model.loadInboxMessageIntoBubble(msg)
                        }
                    }
                    .padding(.vertical, 8)
                    Divider()
                }
            }
        }
    }

    private var optionalWebSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Optional browser")
            Text("The bundled web page is minimal; the Mac app is the full account experience.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Open server in browser") {
                guard let url = serverRootURL() else { return }
                NSWorkspace.shared.open(url)
            }
            .disabled(model.railwayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s)
            .font(.title3.weight(.semibold))
    }

    private func serverRootURL() -> URL? {
        var s = model.railwayBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    private func inboxSenderPrimaryLabel(_ msg: RailwayInboxMessage) -> String {
        if let n = msg.senderDisplayName {
            let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return msg.senderUserId
    }

    private func inboxSenderShowsUserId(_ msg: RailwayInboxMessage) -> Bool {
        guard let n = msg.senderDisplayName else { return false }
        return !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
