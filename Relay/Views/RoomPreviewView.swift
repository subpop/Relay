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

/// A read-only preview of a room the user has not yet joined.
///
/// ``RoomPreviewView`` displays room metadata (name, topic, member count) and,
/// when available, a read-only timeline of recent messages. A prominent join
/// button allows the user to commit to membership after browsing.
///
/// This view is reusable for two contexts:
/// - **Room directory**: browsing a public room before joining.
/// - **Invite preview**: viewing an invited room with inviter context.
///
/// When `inviterName` is provided, an invite banner appears at the top showing
/// who sent the invitation, with both accept and decline actions.
struct RoomPreviewView: View {
    @Environment(\.matrixService) private var matrixService
    let room: DirectoryRoom
    let onJoin: () -> Void
    let onClose: () -> Void

    /// The display name of the user who sent the invite. When non-nil,
    /// the view renders in invite mode with accept/decline actions.
    var inviterName: String?

    /// The `mxc://` avatar URL of the inviter.
    var inviterAvatarURL: String?

    /// Called when the user declines the invitation. Only used in invite mode.
    var onDecline: (() -> Void)?

    /// Whether to show the built-in header bar with back button and room identity.
    ///
    /// Set to `false` when the preview is rendered inline in the detail pane,
    /// where the main window toolbar provides the room identity and navigation.
    var showsHeader: Bool = true

    @State private var viewModel: (any RoomPreviewViewModelProtocol)?

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                previewHeader
                Divider()
            }
            if inviterName != nil {
                inviteBanner
                Divider()
            }
            previewContent
            Divider()
            joinBar
        }
        .onAppear {
            if viewModel == nil {
                viewModel = matrixService.makeRoomPreviewViewModel(roomId: room.roomId)
                Task { await viewModel?.loadPreview() }
            }
        }
    }

    // MARK: - Header

    private var previewHeader: some View {
        HStack(spacing: 12) {
            Button("Back", systemImage: "chevron.left") {
                onClose()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .font(.callout)

            Spacer()

            AvatarView(
                name: viewModel?.roomName ?? room.name ?? room.roomId,
                mxcURL: viewModel?.roomAvatarURL ?? room.avatarURL,
                size: 32
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(viewModel?.roomName ?? room.name ?? room.roomId)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    if let alias = viewModel?.canonicalAlias ?? room.alias {
                        Text(alias)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Label("\(viewModel?.memberCount ?? room.memberCount)", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Invite Banner

    private var inviteBanner: some View {
        HStack(spacing: 10) {
            AvatarView(
                name: inviterName ?? "Unknown",
                mxcURL: inviterAvatarURL,
                size: 28
            )

            VStack(alignment: .leading, spacing: 2) {
                Text("Invitation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("**\(inviterName ?? "Someone")** invited you to join")
                    .font(.callout)
            }

            Spacer()

            if let onDecline {
                Button("Decline", role: .destructive) {
                    onDecline()
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.fill.quaternary)
    }

    // MARK: - Content

    @ViewBuilder
    private var previewContent: some View {
        if let viewModel {
            if viewModel.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Loading preview...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.messages.isEmpty {
                roomInfoPanel(viewModel)
            } else if let timelineVM = viewModel as? any TimelineViewModelProtocol {
                TimelineView(
                    roomId: room.roomId,
                    roomName: viewModel.roomName ?? room.name ?? room.roomId,
                    roomAvatarURL: viewModel.roomAvatarURL ?? room.avatarURL,
                    viewModel: timelineVM,
                    focusedMessageId: .constant(nil),
                    readOnly: true
                )
            } else {
                // Fallback for preview VMs that don't conform to TimelineViewModelProtocol.
                ContentUnavailableView(
                    "Preview Unavailable",
                    systemImage: "eye.slash",
                    description: Text("Unable to load a preview for this room.")
                )
            }
        } else {
            ContentUnavailableView(
                "Preview Unavailable",
                systemImage: "eye.slash",
                description: Text("Unable to load a preview for this room.")
            )
        }
    }

    /// Shows room metadata when no timeline messages are available.
    private func roomInfoPanel(_ viewModel: any RoomPreviewViewModelProtocol) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                AvatarView(
                    name: viewModel.roomName ?? room.roomId,
                    mxcURL: viewModel.roomAvatarURL,
                    size: 80
                )

                VStack(spacing: 4) {
                    Text(viewModel.roomName ?? room.roomId)
                        .font(.title2)
                        .fontWeight(.semibold)

                    if let alias = viewModel.canonicalAlias {
                        Text(alias)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if let topic = viewModel.roomTopic, !topic.isEmpty {
                    Text(topic)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }

                Label("\(viewModel.memberCount) members", systemImage: "person.2")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text("This room does not support timeline preview.\nJoin to see messages.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Join Bar

    private var joinBar: some View {
        HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text(inviterName != nil
                 ? "Accept invitation to participate"
                 : "Join this room to participate")
                .foregroundStyle(.secondary)
            Spacer()
            Button(inviterName != nil ? "Accept & Join" : "Join Room") {
                onJoin()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Previews

#Preview("Room Preview - Directory") {
    RoomPreviewView(
        room: DirectoryRoom(
            roomId: "!test:matrix.org",
            name: "Swift Developers",
            topic: "All things Swift programming",
            alias: "#swift:matrix.org",
            memberCount: 1200,
            isWorldReadable: true
        ),
        onJoin: {},
        onClose: {}
    )
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 600, height: 500)
}

#Preview("Room Preview - Invite") {
    RoomPreviewView(
        room: DirectoryRoom(
            roomId: "!invite:matrix.org",
            name: "Design Team",
            topic: "UI/UX design discussion"
        ),
        onJoin: {},
        onClose: {},
        inviterName: "Alice",
        inviterAvatarURL: nil,
        onDecline: {}
    )
    .environment(\.matrixService, PreviewMatrixService())
    .frame(width: 600, height: 500)
}
