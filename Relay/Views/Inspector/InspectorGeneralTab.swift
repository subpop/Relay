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

/// The General tab of the timeline inspector, displaying the room's avatar, name,
/// topic, encryption and visibility badges, about info, pinned messages, and room ID.
struct InspectorGeneralTab: View {
    let viewModel: TimelineInspectorViewModel
    var context: InspectorContext = .room

    /// Called when a pinned message row is tapped. Passes the event ID to scroll to.
    var onPinnedMessageTap: ((String) -> Void)?

    var body: some View {
        Group {
            if let details = viewModel.details {
                detailContent(details)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Content

    private func detailContent(_ details: RoomDetails) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                InspectorHeaderSection(details: details, context: context)
                InspectorAboutSection(details: details)
                if context == .room, !details.pinnedEventIds.isEmpty {
                    InspectorPinnedSection(
                        details: details,
                        onPinnedMessageTap: onPinnedMessageTap
                    )
                }
                InspectorFooterSection(roomId: details.id)
            }
            .padding(.vertical)
        }
    }
}

// MARK: - Header Section

private struct InspectorHeaderSection: View {
    let details: RoomDetails
    var context: InspectorContext = .room

    var body: some View {
        VStack(spacing: 6) {
            AvatarView(name: details.name, mxcURL: details.avatarURL, size: 80)
                .shadow(color: .black.opacity(0.1), radius: 4, y: 2)

            Text(details.name)
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

            HStack(spacing: 12) {
                switch context {
                case .room:
                    InspectorBadge(
                        icon: details.isEncrypted ? "lock.fill" : "lock.open",
                        label: details.isEncrypted ? "Encrypted" : "Unencrypted",
                        color: details.isEncrypted ? .green : .secondary
                    )

                    InspectorBadge(
                        icon: details.isPublic ? "globe" : "lock.shield",
                        label: details.isPublic ? "Public" : "Private",
                        color: details.isPublic ? .blue : .secondary
                    )

                    if details.isDirect {
                        InspectorBadge(icon: "person.fill", label: "Direct", color: .orange)
                    }

                case .space:
                    InspectorBadge(icon: "square.stack.3d.up", label: "Space", color: .purple)

                    InspectorBadge(
                        icon: details.isPublic ? "globe" : "lock.shield",
                        label: details.isPublic ? "Public" : "Private",
                        color: details.isPublic ? .blue : .secondary
                    )
                }
            }
            .padding(.top, 4)
        }
        .padding(.horizontal)
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

// MARK: - Pinned Section

private struct InspectorPinnedSection: View {
    let details: RoomDetails
    var onPinnedMessageTap: ((String) -> Void)?

    var body: some View {
        GroupBox {
            PinnedMessagesView(
                roomId: details.id,
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

/// A small pill badge showing an icon and label with a tinted background.
struct InspectorBadge: View {
    let icon: String
    let label: String
    let color: Color

    var body: some View {
        Label(label, systemImage: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
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
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}

#Preview("Space") {
    InspectorGeneralTab(viewModel: .preview(context: .space), context: .space)
        .environment(\.matrixService, PreviewMatrixService())
        .frame(width: 280, height: 600)
}
