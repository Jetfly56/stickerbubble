import AppKit
import Combine
import SwiftUI

/// In-app account, server URL, contacts, and inbox triage — no browser required.
struct SyncHubView: View {
    @ObservedObject var model: BubbleModel

    @State private var newContactName = ""
    @State private var newPeerDeviceId = ""
    @State private var serverURLDraft = ""
    @State private var deviceIdDraft = ""
    @State private var deviceIdApplyError: String?
    @State private var confirmRegenerateDevice = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Everything here syncs with your Railway server. The website is optional for triage in a browser.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                accountSection
                serverSection
                contactsSection
                inboxSection
                optionalWebSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 520)
        .onAppear {
            serverURLDraft = model.railwayBaseURL
            deviceIdDraft = model.deviceId
            Task {
                await model.refreshRemoteContacts()
                await model.refreshInboxTriage()
            }
        }
        .onReceive(model.$deviceId) { newId in
            deviceIdDraft = newId
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Account")
            Text("Pick a device ID you share with friends (or keep a random one). Your display name is sent with each sticker so they see who it is from.")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("Display name (sent with messages)", text: $model.localDisplayName)
                .textFieldStyle(.roundedBorder)
            Button("Save display name") {
                model.saveLocalDisplayName()
            }

            TextField("Your device ID (2–64: letters, numbers, . _ -)", text: $deviceIdDraft)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            if let err = deviceIdApplyError, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button("Save device ID") {
                    deviceIdApplyError = model.applyDeviceId(deviceIdDraft)
                    if deviceIdApplyError == nil {
                        deviceIdDraft = model.deviceId
                        Task {
                            await model.refreshRemoteContacts()
                            await model.refreshInboxTriage()
                        }
                    }
                }
                Button("Copy device ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.deviceId, forType: .string)
                }
                Button("New random ID…", role: .destructive) {
                    confirmRegenerateDevice = true
                }
            }
        }
        .alert("Replace device ID?", isPresented: $confirmRegenerateDevice) {
            Button("Cancel", role: .cancel) {}
            Button("Generate", role: .destructive) {
                model.regenerateDeviceId()
                deviceIdDraft = model.deviceId
                deviceIdApplyError = nil
            }
        } message: {
            Text("You will get a new random ID. Old messages won’t find you; tell contacts your new ID.")
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
                    await model.refreshRemoteContacts()
                    await model.refreshInboxTriage()
                }
            }
        }
    }

    private var contactsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Contacts")
            Text("Leave name empty to use the display name from their latest message to you, if any; otherwise their device ID is used as the label.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(alignment: .top, spacing: 10) {
                TextField("Name (optional)", text: $newContactName)
                    .textFieldStyle(.roundedBorder)
                TextField("Their device ID", text: $newPeerDeviceId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            Button("Add contact") {
                Task {
                    await model.addRemoteContact(displayName: newContactName, peerDeviceId: newPeerDeviceId)
                    newContactName = ""
                    newPeerDeviceId = ""
                }
            }
            .disabled(newPeerDeviceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if model.remoteContacts.isEmpty {
                Text("No contacts yet.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(model.remoteContacts) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.displayName).font(.headline)
                            Text(c.peerDeviceId).font(.caption).monospaced().foregroundStyle(.secondary)
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
            HStack {
                Button("Refresh inbox") {
                    Task { await model.refreshInboxTriage() }
                }
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
                                if inboxSenderShowsDeviceId(msg) {
                                    Text(msg.senderDeviceId)
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
            Text("Open the same server in Safari or Chrome if you prefer a tab for bulk triage.")
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
        return msg.senderDeviceId
    }

    private func inboxSenderShowsDeviceId(_ msg: RailwayInboxMessage) -> Bool {
        guard let n = msg.senderDisplayName else { return false }
        return !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
