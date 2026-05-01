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

/// Displays a compact list of pinned messages for a room.
///
/// ``PinnedMessagesView`` fetches pinned messages via the Matrix service and renders
/// each one as a compact row with sender avatar, name, message preview, and timestamp.
/// It is used both in the toolbar capsule popover and inline in ``RoomInfoView``.
struct PinnedMessagesView: View {
    @Environment(\.matrixService) private var matrixService

    /// The Matrix room identifier to fetch pinned messages for.
    let roomId: String

    /// When `true`, wraps the content in its own `ScrollView`. Set to `false` when
    /// embedding inside another scrollable container (e.g. ``RoomInfoView``).
    var scrollable: Bool = true

    /// Called when a pinned message row is tapped. Passes the event ID so the
    /// caller can scroll the main timeline to that message.
    var onSelectMessage: ((String) -> Void)?

    @State private var pinnedMessages: [TimelineMessage]?

    var body: some View {
        Group {
            if let pinnedMessages {
                if pinnedMessages.isEmpty {
                    emptyState
                } else {
                    messageList(pinnedMessages)
                }
            } else {
                ProgressView()
                    .frame(width: 200, height: 80)
            }
        }
        .task {
            pinnedMessages = await matrixService.pinnedMessages(roomId: roomId)
        }
    }

    // MARK: - Message List

    @ViewBuilder
    private func messageList(_ messages: [TimelineMessage]) -> some View {
        let content = VStack(spacing: 0) {
            ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                if index > 0 {
                    Divider().padding(.leading, 40)
                }
                pinnedMessageRow(message)
            }
        }

        if scrollable {
            ScrollView {
                content
                    .padding(.vertical, 4)
            }
            .frame(width: 300)
            .frame(maxHeight: 400)
        } else {
            content
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func pinnedMessageRow(_ message: TimelineMessage) -> some View {
        let content = HStack(alignment: .top, spacing: 8) {
            AvatarView(
                name: message.displayName,
                mxcURL: message.senderAvatarURL,
                size: 24
            )
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(message.displayName)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Spacer()

                    Text(message.formattedTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Text(message.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        if let onSelectMessage {
            Button {
                onSelectMessage(message.eventID)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            content
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "pin.slash")
                .font(.title2)
                .foregroundStyle(.quaternary)
            Text("No Pinned Messages")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(width: 200, height: 80)
    }
}

#Preview("With Messages") {
    PinnedMessagesView(roomId: "!design:matrix.org")
        .environment(\.matrixService, PreviewMatrixService())
}

#Preview("Empty") {
    PinnedMessagesView(roomId: "!hq:matrix.org")
        .environment(\.matrixService, PreviewMatrixService())
}
