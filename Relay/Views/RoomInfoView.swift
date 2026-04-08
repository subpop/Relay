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

import RelayInterface
import SwiftUI

/// An inspector panel that displays detailed information about a room -- avatar, name,
/// topic, encryption status, member list, and room ID.
struct RoomInfoView: View {
    @Environment(\.matrixService) private var matrixService

    /// The Matrix room identifier to display information for.
    let roomId: String

    /// Called when a member row is tapped to show their user profile.
    var onMemberTap: ((UserProfile) -> Void)?

    /// Called when a pinned message row is tapped. Passes the event ID to scroll to.
    var onPinnedMessageTap: ((String) -> Void)?

    @State private var details: RoomDetails?

    /// Maximum number of member rows shown in the info panel.
    private let maxVisibleMembers = 20

    var body: some View {
        Group {
            if let details {
                detailContent(details)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
        .task {
            details = await matrixService.roomDetails(roomId: roomId)
        }
    }

    // MARK: - Content

    private func detailContent(_ details: RoomDetails) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection(details)
                aboutSection(details)
                if !details.pinnedEventIds.isEmpty {
                    pinnedSection(details)
                }
                membersSection(details)
                footerSection(details)
            }
            .padding(.vertical, 16)
        }
    }

    // MARK: - Header

    private func headerSection(_ details: RoomDetails) -> some View {
        VStack(spacing: 6) {
            AvatarView(name: details.name, mxcURL: details.avatarURL, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text(details.name)
                .font(.title3)
                .fontWeight(.semibold)

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

            HStack(spacing: 12) {
                badge(
                    icon: details.isEncrypted ? "lock.fill" : "lock.open",
                    label: details.isEncrypted ? "Encrypted" : "Unencrypted",
                    color: details.isEncrypted ? .green : .secondary
                )

                badge(
                    icon: details.isPublic ? "globe" : "lock.shield",
                    label: details.isPublic ? "Public" : "Private",
                    color: details.isPublic ? .blue : .secondary
                )

                if details.isDirect {
                    badge(icon: "person.fill", label: "Direct", color: .orange)
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 16)
    }

    private func badge(icon: String, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text(label)
        }
        .font(.caption2)
        .fontWeight(.medium)
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.1), in: Capsule())
    }

    // MARK: - About

    private func aboutSection(_ details: RoomDetails) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                infoRow(label: "Members", value: "\(details.memberCount)")

                if let alias = details.canonicalAlias {
                    Divider().padding(.vertical, 4)
                    infoRow(label: "Alias", value: alias)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Info", systemImage: "info.circle")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    private func infoRow(label: String, value: String) -> some View {
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

    // MARK: - Pinned Messages

    private func pinnedSection(_ details: RoomDetails) -> some View {
        GroupBox {
            PinnedMessagesView(roomId: details.id, scrollable: false, onSelectMessage: onPinnedMessageTap)
                .padding(.vertical, 2)
        } label: {
            Label("Pinned (\(details.pinnedEventIds.count))", systemImage: "pin.fill")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Members

    private func membersSection(_ details: RoomDetails) -> some View {
        let visibleMembers = Array(details.members.prefix(maxVisibleMembers))
        let remainingCount = Int(details.memberCount) - visibleMembers.count

        return GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(visibleMembers.enumerated()), id: \.element.id) { index, member in
                    if index > 0 {
                        Divider().padding(.vertical, 4)
                    }
                    memberRow(member)
                }

                if remainingCount > 0 {
                    Divider().padding(.vertical, 4)
                    Text("\(remainingCount) more")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Label("Members (\(details.memberCount))", systemImage: "person.2")
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private func memberRow(_ member: RoomMemberDetails) -> some View {
        let content = HStack(spacing: 8) {
            AvatarView(
                name: member.displayName ?? member.userId,
                mxcURL: member.avatarURL,
                size: 28
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(member.displayName ?? member.userId)
                    .font(.callout)
                    .lineLimit(1)

                if member.displayName != nil {
                    Text(member.userId)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if member.role != .user {
                Text(member.role.rawValue.capitalized)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundStyle(member.role == .administrator ? .orange : .blue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        (member.role == .administrator ? Color.orange : Color.blue).opacity(0.1),
                        in: Capsule()
                    )
            }
        }

        if let onMemberTap {
            Button {
                onMemberTap(UserProfile(member: member))
            } label: {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    // MARK: - Footer

    private func footerSection(_ details: RoomDetails) -> some View {
        Text(details.id)
            .font(.caption2)
            .foregroundStyle(.quaternary)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.top, 4)
    }
}

#Preview {
    RoomInfoView(roomId: "!design:matrix.org")
        .environment(\.matrixService, PreviewMatrixService())
        .frame(height: 500)
}
