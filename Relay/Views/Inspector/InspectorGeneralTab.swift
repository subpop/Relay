// Copyright 2026 Link Dupont
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import MatrixKit
import SwiftUI
import UniformTypeIdentifiers

/// The General tab of the timeline inspector, displaying the room's avatar, name,
/// topic, encryption and visibility badges, about info, pinned messages, and room ID.
///
/// When the current user has permission to edit room details, a pencil icon appears
/// on the avatar. Tapping it enters inline editing mode where the name and topic
/// become text fields and avatar change/remove buttons appear. A Save button
/// commits the changes.
struct InspectorGeneralTab: View {
    let viewModel: TimelineInspectorViewModel
    var context: InspectorContext = .room

    /// Called when a pinned message row is tapped. Passes the event ID to scroll to.
    var onPinnedMessageTap: ((String) -> Void)?

    @State private var isEditing = false
    @State private var editName = ""
    @State private var editTopic = ""
    @State private var editJoinRule = "invite"
    @State private var editIsPublic = false
    @State private var editHistoryVisibility = "shared"
    @State private var isSaving = false
    @State private var showImagePicker = false

    private var permissions: RoomPermissions? { viewModel.permissions }
    private var canEditName: Bool { permissions?.canEditName ?? false }
    private var canEditTopic: Bool { permissions?.canEditTopic ?? false }
    private var canEditAvatar: Bool { permissions?.canEditAvatar ?? false }
    private var canEditJoinRules: Bool { viewModel.canEditJoinRules }
    private var canEditCanonicalAlias: Bool { viewModel.canEditCanonicalAlias }
    /// Directory visibility is a server-side setting that requires admin privileges.
    private var canEditVisibility: Bool { viewModel.isCurrentUserAdmin }
    private var canEditHistoryVisibility: Bool { viewModel.canEditHistoryVisibility }
    private var isSpace: Bool { context == .space }
    private var entityName: String { isSpace ? "space" : "room" }

    var body: some View {
        Group {
            if let details = viewModel.details {
                detailContent(details)
            } else if viewModel.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("Couldn't Load Room", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(viewModel.loadError ?? "Room details are unavailable.")
                } actions: {
                    Button("Retry") {
                        Task { await viewModel.retryLoading() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .disabled(isSaving)
        .fileImporter(
            isPresented: $showImagePicker,
            allowedContentTypes: [.png, .jpeg, .gif],
            allowsMultipleSelection: false
        ) { result in
            handleImageSelection(result)
        }
    }

    // MARK: - Content

    private func detailContent(_ details: RoomDetails) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection(details)
                if isEditing, isSpace {
                    spaceAccessSections(details)
                }
                if !isEditing {
                    InspectorAboutSection(details: details)
                }
                if !isEditing, canEditCanonicalAlias {
                    InspectorAliasSection(viewModel: viewModel)
                }
                if context == .room, !details.pinnedEventIds.isEmpty, !isEditing {
                    InspectorPinnedSection(
                        details: details,
                        onPinnedMessageTap: onPinnedMessageTap
                    )
                }
                if !isEditing {
                    InspectorFooterSection(roomId: details.id.value)
                }
            }
            .padding(.vertical)
        }
        .overlay(alignment: .top) {
            if isEditing {
                editingToolbar(details)
            }
        }
    }

    // MARK: - Editing Toolbar

    private func editingToolbar(_ details: RoomDetails) -> some View {
        HStack {
            Button {
                isEditing = false
            } label: {
                Image(systemName: "xmark")
                    .font(.callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(.regularMaterial, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Discard changes")

            Spacer()

            Button {
                save(details)
            } label: {
                Image(systemName: "checkmark")
                    .font(.callout)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(.tint, in: .circle)
            }
            .buttonStyle(.plain)
            .help("Save changes")
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
    }

    // MARK: - Header Section

    private func headerSection(_ details: RoomDetails) -> some View {
        VStack(spacing: 6) {
            // Avatar with overlay controls
            AvatarView(name: details.name ?? details.id.value, mxcURL: details.avatarURL?.value, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
                .overlay(alignment: .bottomTrailing) {
                    if isEditing, canEditAvatar {
                        // Camera overlay to change avatar
                        Button { showImagePicker = true } label: {
                            Image(systemName: "camera.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.tint, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Change avatar")
                    } else if viewModel.canEditRoomDetails, !isEditing {
                        // Pencil overlay to enter edit mode
                        Button { enterEditMode(details) } label: {
                            Image(systemName: "pencil")
                                .font(.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.tint, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Edit room details")
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isEditing, canEditAvatar, details.avatarURL != nil {
                        // Trash overlay to remove avatar
                        Button {
                            performUpdate { try await viewModel.removeRoomAvatar() }
                        } label: {
                            Image(systemName: "trash.fill")
                                .font(.caption2)
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(.red, in: .circle)
                        }
                        .buttonStyle(.plain)
                        .help("Remove avatar")
                    }
                }

            if isEditing {
                editingFields(details)
            } else {
                readOnlyFields(details)
            }

            statusTiles(details)
        }
        .overlay(alignment: .topTrailing) {
            if !isEditing {
                ShareLink(
                    item: matrixToURL(for: details),
                    preview: SharePreview(details.name ?? details.id.value)
                ) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Share \(entityName)")
            }
        }
        .padding(.horizontal)
    }

    // MARK: - Read-Only Fields

    private func readOnlyFields(_ details: RoomDetails) -> some View {
        Group {
            Text(details.name ?? details.id.value)
                .font(.title3)
                .bold()

            if let alias = details.canonicalAlias {
                Text(alias)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if let topic = details.topic, !topic.isEmpty {
                Text(topic)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
    }

    // MARK: - Editing Fields

    private func editingFields(_ details: RoomDetails) -> some View {
        VStack(spacing: 10) {
            // Name field
            if canEditName {
                TextField("Name", text: $editName)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            } else {
                Text(details.name ?? details.id.value)
                    .font(.title3)
                    .bold()
            }

            // Topic field
            if canEditTopic {
                TextField("Topic", text: $editTopic, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .lineLimit(2...4)
                    .multilineTextAlignment(.center)
            } else if let topic = details.topic, !topic.isEmpty {
                Text(topic)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }


        }
    }

    // MARK: - Share URL

    /// Builds a `https://matrix.to` URL for the room or space, preferring the
    /// canonical alias (human-readable) and falling back to the room ID.
    private func matrixToURL(for details: RoomDetails) -> URL {
        let identifier = details.canonicalAlias ?? details.id.value
        let encoded = identifier.addingPercentEncoding(
            withAllowedCharacters: .urlFragmentAllowed
        )!
        return URL(string: "https://matrix.to/#/\(encoded)")!
    }

    // MARK: - Status Tiles

    private func statusTiles(_ details: RoomDetails) -> some View {
        HStack(spacing: 8) {
            switch context {
            case .room:
                InspectorTile(
                    icon: details.isEncrypted ? "lock.fill" : "lock.open",
                    title: "Encryption",
                    status: details.isEncrypted ? "On" : "Off",
                    color: details.isEncrypted ? .green : .secondary
                )

                InspectorTile(
                    icon: details.isPublic ? "globe" : "lock.shield",
                    title: "Visibility",
                    status: details.isPublic ? "Public" : "Private",
                    color: details.isPublic ? .blue : .secondary
                )

                if details.isDirect {
                    InspectorTile(
                        icon: "person.fill",
                        title: "Type",
                        status: "Direct",
                        color: .orange
                    )
                }

            case .space:
                InspectorTile(
                    icon: "square.stack.3d.up",
                    title: "Type",
                    status: "Space",
                    color: .purple
                )

                InspectorTile(
                    icon: details.isPublic ? "globe" : "lock.shield",
                    title: "Visibility",
                    status: details.isPublic ? "Public" : "Private",
                    color: details.isPublic ? .blue : .secondary
                )
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Edit Mode

    private func enterEditMode(_ details: RoomDetails) {
        editName = details.name ?? ""
        editTopic = details.topic ?? ""
        editJoinRule = details.joinRule ?? "invite"
        editIsPublic = details.isPublic
        editHistoryVisibility = details.historyVisibility ?? "shared"
        isEditing = true
    }

    // MARK: - Save

    private func save(_ details: RoomDetails) {
        let trimmedName = editName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTopic = editTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = canEditName && !trimmedName.isEmpty && trimmedName != (details.name ?? "")
        let topicChanged = canEditTopic && trimmedTopic != (details.topic ?? "")
        let joinRuleChanged = isSpace && canEditJoinRules && editJoinRule != (details.joinRule ?? "invite")
        let visibilityChanged = isSpace && canEditVisibility && editIsPublic != details.isPublic
        let historyChanged = isSpace && canEditHistoryVisibility
            && editHistoryVisibility != (details.historyVisibility ?? "shared")

        guard nameChanged || topicChanged || joinRuleChanged
                || visibilityChanged || historyChanged else {
            isEditing = false
            return
        }

        isSaving = true
        Task {
            defer {
                isSaving = false
                isEditing = false
            }
            if nameChanged {
                try? await viewModel.setRoomName(trimmedName)
            }
            if topicChanged {
                try? await viewModel.setRoomTopic(trimmedTopic)
            }
            if joinRuleChanged {
                try? await viewModel.updateJoinRule(editJoinRule)
            }
            if visibilityChanged {
                try? await viewModel.updateRoomVisibility(isPublic: editIsPublic)
            }
            if historyChanged {
                try? await viewModel.updateHistoryVisibility(editHistoryVisibility)
            }
        }
    }

    // MARK: - Image Handling

    private func handleImageSelection(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        guard let data = try? Data(contentsOf: url) else { return }
        let ext = url.pathExtension.lowercased()
        let mimeType: String = switch ext {
        case "png": "image/png"
        case "gif": "image/gif"
        default: "image/jpeg"
        }
        performUpdate { try await viewModel.uploadRoomAvatar(mimeType: mimeType, data: data) }
    }

    // MARK: - Space Access Sections

    @ViewBuilder
    private func spaceAccessSections(_ details: RoomDetails) -> some View {
        // Join Rule
        GroupBox {
            if canEditJoinRules {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Join Rule", selection: $editJoinRule) {
                        Label("Anyone Can Join", systemImage: "globe").tag("public")
                        Label("Invite Only", systemImage: "envelope").tag("invite")
                        Label("Request to Join", systemImage: "hand.raised").tag("knock")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(RoomAccessLabels.joinRuleDescription(editJoinRule, entityName: entityName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: RoomAccessLabels.joinRuleIcon(details.joinRule),
                    color: .secondary,
                    title: RoomAccessLabels.joinRuleLabel(details.joinRule),
                    detail: RoomAccessLabels.joinRuleDescription(details.joinRule, entityName: entityName)
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Who Can Join", systemImage: "door.left.hand.open")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)

        // Directory Visibility
        GroupBox {
            if canEditVisibility {
                Toggle(isOn: $editIsPublic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Listed in Room Directory")
                            .font(.callout)
                        Text(editIsPublic
                             ? "This \(entityName) appears in the public directory."
                             : "This \(entityName) is hidden from the public directory.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: details.isPublic ? "globe" : "eye.slash",
                    color: details.isPublic ? .blue : .secondary,
                    title: details.isPublic ? "Public Directory" : "Private",
                    detail: details.isPublic
                        ? "This \(entityName) appears in the public directory."
                        : "This \(entityName) is hidden from the public directory."
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Directory Visibility", systemImage: "globe")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)

        // History Visibility
        GroupBox {
            if canEditHistoryVisibility {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("History Visibility", selection: $editHistoryVisibility) {
                        Label("Since Joined", systemImage: "person.badge.key").tag("joined")
                        Label("Since Invited", systemImage: "envelope").tag("invited")
                        Label("Full History", systemImage: "person.2").tag("shared")
                        Label("Anyone (World Readable)", systemImage: "globe").tag("world_readable")
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)

                    Text(RoomAccessLabels.historyDescription(editHistoryVisibility))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            } else {
                SecurityStatusRow(
                    icon: RoomAccessLabels.historyIcon(details.historyVisibility),
                    color: RoomAccessLabels.historyColor(details.historyVisibility),
                    title: RoomAccessLabels.historyLabel(details.historyVisibility),
                    detail: RoomAccessLabels.historyDescription(details.historyVisibility)
                )
                .padding(.vertical, 2)
            }
        } label: {
            Label("Who Can Read History", systemImage: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private func performUpdate(_ action: @escaping () async throws -> Void) {
        isSaving = true
        Task {
            defer { isSaving = false }
            try? await action()
        }
    }
}

// MARK: - About Section

private struct InspectorAboutSection: View {
    let details: RoomDetails

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                InspectorInfoRow(label: "Members", value: "\(details.memberCount)")

                if let alias = details.canonicalAlias {
                    Divider().padding(.vertical, 4)
                    InspectorInfoRow(label: "Alias", value: alias)
                }

                if !details.alternativeAliases.isEmpty {
                    Divider().padding(.vertical, 4)
                    InspectorInfoRow(
                        label: "Additional Aliases",
                        value: "\(details.alternativeAliases.count)"
                    )
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Info", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

// MARK: - Alias Management Section

/// Displays and manages room aliases (canonical and alternative) for users
/// with `canEditCanonicalAlias` permission.
private struct InspectorAliasSection: View {
    let viewModel: TimelineInspectorViewModel

    @State private var isAddingAlias = false
    @State private var newAliasLocalPart = ""
    @State private var aliasError: String?
    @State private var isProcessing = false

    private var details: RoomDetails? { viewModel.details }
    private var canonicalAlias: String? { details?.canonicalAlias }
    private var altAliases: [String] { details?.alternativeAliases ?? [] }

    /// All aliases (canonical first, then alternatives) for display.
    private var allAliases: [String] {
        var result: [String] = []
        if let canonical = canonicalAlias {
            result.append(canonical)
        }
        result.append(contentsOf: altAliases)
        return result
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if allAliases.isEmpty {
                    Text("No aliases configured")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                } else {
                    ForEach(Array(allAliases.enumerated()), id: \.element) { index, alias in
                        if index > 0 {
                            Divider().padding(.vertical, 4)
                        }
                        aliasRow(alias)
                    }
                }

                if isAddingAlias {
                    if !allAliases.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                    addAliasField
                }
            }
            .padding(.vertical, 2)
        } label: {
            HStack {
                Label("Aliases", systemImage: "number")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !isAddingAlias {
                    Button {
                        isAddingAlias = true
                        newAliasLocalPart = ""
                        aliasError = nil
                    } label: {
                        Image(systemName: "plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Add alias")
                }
            }
        }
        .disabled(isProcessing)
        .padding(.horizontal)
    }

    // MARK: - Alias Row

    private func aliasRow(_ alias: String) -> some View {
        HStack(spacing: 6) {
            if alias == canonicalAlias {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Primary alias")
            } else {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .hidden()
            }

            Text(alias)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer()
        }
        .contextMenu {
            if alias != canonicalAlias {
                Button("Set as Primary", systemImage: "star") {
                    setAsPrimary(alias)
                }
            }
            Button("Remove", systemImage: "trash", role: .destructive) {
                removeAlias(alias)
            }
        }
    }

    // MARK: - Add Alias Field

    private var addAliasField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("#")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)

                TextField("localpart", text: $newAliasLocalPart)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { addAlias() }

                if let homeserver = viewModel.homeserver {
                    Text(":\(homeserver)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Button("Cancel") {
                    isAddingAlias = false
                    aliasError = nil
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button("Add") {
                    addAlias()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(newAliasLocalPart.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let error = aliasError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - Actions

    private func addAlias() {
        let localPart = newAliasLocalPart.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !localPart.isEmpty else { return }
        guard let homeserver = viewModel.homeserver else {
            aliasError = "Unable to determine homeserver."
            return
        }

        let fullAlias = "#\(localPart):\(homeserver)"
        isProcessing = true
        aliasError = nil

        Task {
            defer { isProcessing = false }
            do {
                // Check availability first.
                let available = try await viewModel.isRoomAliasAvailable(fullAlias)
                guard available else {
                    aliasError = "Alias is already in use."
                    return
                }

                // Publish the alias in the room directory.
                try await viewModel.publishRoomAlias(fullAlias)

                // Add to the canonical alias state event.
                if canonicalAlias == nil {
                    // No canonical alias yet -- set this as the primary.
                    try await viewModel.updateCanonicalAlias(fullAlias, altAliases: altAliases)
                } else {
                    // Append as an alternative alias.
                    var updatedAlt = altAliases
                    updatedAlt.append(fullAlias)
                    try await viewModel.updateCanonicalAlias(canonicalAlias, altAliases: updatedAlt)
                }

                isAddingAlias = false
                newAliasLocalPart = ""
            } catch {
                aliasError = error.localizedDescription
            }
        }
    }

    private func setAsPrimary(_ alias: String) {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            // Build the new alt aliases list: old canonical (if any) + remaining alts,
            // excluding the alias being promoted.
            var newAlt = altAliases.filter { $0 != alias }
            if let oldCanonical = canonicalAlias {
                newAlt.insert(oldCanonical, at: 0)
            }
            try? await viewModel.updateCanonicalAlias(alias, altAliases: newAlt)
        }
    }

    private func removeAlias(_ alias: String) {
        isProcessing = true
        Task {
            defer { isProcessing = false }
            // Unpublish from the room directory.
            _ = try? await viewModel.removeRoomAlias(alias)

            // Update the canonical alias state event.
            if alias == canonicalAlias {
                // Removing the canonical -- promote the first alt, or clear.
                let newCanonical = altAliases.first
                let newAlt = Array(altAliases.dropFirst())
                try? await viewModel.updateCanonicalAlias(newCanonical, altAliases: newAlt)
            } else {
                // Removing an alternative alias.
                let newAlt = altAliases.filter { $0 != alias }
                try? await viewModel.updateCanonicalAlias(canonicalAlias, altAliases: newAlt)
            }
        }
    }
}

// MARK: - Pinned Section

private struct InspectorPinnedSection: View {
    let details: RoomDetails
    var onPinnedMessageTap: ((String) -> Void)?

    var body: some View {
        GroupBox {
            PinnedMessagesView(
                roomId: details.id.value,
                scrollable: false,
                onSelectMessage: onPinnedMessageTap
            )
            .padding(.vertical, 2)
        } label: {
            Label("Pinned (\(details.pinnedEventIds.count))", systemImage: "pin.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}

// MARK: - Footer Section

private struct InspectorFooterSection: View {
    let roomId: String

    var body: some View {
        Text(roomId)
            .font(.caption2)
            .foregroundStyle(.quaternary)
            .textSelection(.enabled)
            .padding(.horizontal)
            .padding(.top, 4)
    }
}

// MARK: - Shared Components

/// A compact tile showing an icon, category title, and status value.
struct InspectorTile: View {
    let icon: String
    let title: String
    let status: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(color)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Text(status)
                .font(.caption)
                .bold()
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}

/// A horizontal key-value row used in inspector GroupBox sections.
struct InspectorInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(1)
        }
    }
}

#Preview("Room") {
    InspectorGeneralTab(viewModel: .preview())
        .frame(width: 280, height: 600)
}

#Preview("Room (Admin)") {
    InspectorGeneralTab(viewModel: .preview(asAdmin: true))
        .frame(width: 280, height: 600)
}

#Preview("Direct") {
    InspectorGeneralTab(viewModel: .preview(isDirect: true))
        .frame(width: 280, height: 600)
}

#Preview("Space") {
    InspectorGeneralTab(viewModel: .preview(context: .space), context: .space)
        .frame(width: 280, height: 600)
}

#Preview("Space (Admin)") {
    InspectorGeneralTab(viewModel: .preview(context: .space, asAdmin: true), context: .space)
        .frame(width: 280, height: 600)
}
