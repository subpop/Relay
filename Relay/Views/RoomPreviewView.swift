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
struct RoomPreviewView: View {
    @Environment(\.matrixService) private var matrixService
    let room: DirectoryRoom
    let onJoin: () -> Void
    let onClose: () -> Void

    @State private var viewModel: (any RoomPreviewViewModelProtocol)?

    var body: some View {
        VStack(spacing: 0) {
            previewHeader
            Divider()
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
            Button {
                onClose()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                    Text("Back")
                }
                .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

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
            } else {
                previewTimeline(viewModel)
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

    /// Shows a read-only timeline of messages.
    private func previewTimeline(_ viewModel: any RoomPreviewViewModelProtocol) -> some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(viewModel.messages) { message in
                    PreviewMessageRow(message: message)
                }
            }
            .padding(.vertical, 8)
        }
        .defaultScrollAnchor(.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Join Bar

    private var joinBar: some View {
        HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundStyle(.secondary)
            Text("Join this room to participate")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Join Room") {
                onJoin()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Preview Message Row

/// A simplified, read-only message row for room preview timelines.
private struct PreviewMessageRow: View {
    let message: TimelineMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            AvatarView(
                name: message.senderDisplayName ?? message.senderID,
                mxcURL: message.senderAvatarURL,
                size: 28
            )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.senderDisplayName ?? message.senderID)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)

                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(message.body)
                    .font(.body)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Previews

#Preview("Room Preview") {
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
