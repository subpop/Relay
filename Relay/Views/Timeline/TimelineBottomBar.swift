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

/// The bottom bar for the timeline, showing either the compose bar or a
/// room-upgraded banner. Reports its rendered height via `onHeightChanged`
/// so the parent can adjust content insets for the underlying scroll view.
struct TimelineBottomBar: View {
    @Bindable var compose: ComposeViewModel
    let viewModel: TimelineViewModel
    let roomId: String
    var successorRoomId: String?
    var onRoomTap: ((String) -> Void)?
    var onSendWillScroll: () -> Void
    var onHeightChanged: (CGFloat) -> Void

    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @Environment(\.gifSearchService) private var gifSearchService

    @AppStorage("safety.sendTypingNotifications") private var sendTypingNotifications = true

    @State private var isJoiningSuccessor = false

    var body: some View {
        Group {
            if successorRoomId != nil {
                roomUpgradedBanner
            } else {
                composeBarSection
            }
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            onHeightChanged(height)
        }
    }

    // MARK: - Compose Bar

    private var composeBarSection: some View {
        ComposeBar(
            compose: compose,
            onSend: {
                compose.send(
                    using: viewModel,
                    client: client,
                    sendTypingNotifications: sendTypingNotifications
                ) {
                    onSendWillScroll()
                }
            },
            onAttach: { urls in
                compose.stageAttachments(urls, errorReporter: errorReporter)
            },
            onGIFSelected: { gif in
                compose.sendGIF(
                    gif,
                    using: viewModel,
                    gifSearchService: gifSearchService,
                    errorReporter: errorReporter
                ) {
                    onSendWillScroll()
                }
            },
            roomId: RoomId(unchecked: viewModel.roomId),
            onStickerSelected: { image, shortcode in
                compose.sendSticker(image, shortcode: shortcode, using: viewModel) {
                    onSendWillScroll()
                }
            },
            onPollCreated: { question, options, maxSelections, kind in
                await viewModel.startPoll(
                    question: question, options: options,
                    maxSelections: maxSelections, kind: kind)
                onSendWillScroll()
            }
        )
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .task { await client.refreshUploadSizeLimit() }
        .onChange(of: client.uploadSizeLimit, initial: true) { _, limit in
            compose.maxUploadSize = limit
        }
        .alert("Message Too Long", isPresented: $compose.isShowingOversizedTextAlert) {
            if compose.editingMessage == nil {
                Button("Send as File") {
                    compose.sendTextAsFile(
                        using: viewModel, client: client,
                        sendTypingNotifications: sendTypingNotifications,
                        errorReporter: errorReporter
                    ) {
                        onSendWillScroll()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: {
            if compose.editingMessage == nil {
                Text("This message is too long to send as text. You can send it as a text file instead.")
            } else {
                Text("This message is too long to send as text. Shorten it to save the edit.")
            }
        }
        .alert(
            "File Too Large",
            isPresented: Binding(
                get: { compose.oversizedAttachment != nil },
                set: { if !$0 { compose.oversizedAttachment = nil } }),
            presenting: compose.oversizedAttachment
        ) { attachment in
            if ICloudLinkPublisher.isAvailable {
                Button("Send iCloud Link") {
                    compose.sendICloudLink(
                        for: attachment, using: viewModel, client: client,
                        sendTypingNotifications: sendTypingNotifications,
                        errorReporter: errorReporter
                    ) {
                        onSendWillScroll()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { attachment in
            let limit = Int64(compose.maxUploadSize ?? 0).formatted(.byteCount(style: .file))
            if ICloudLinkPublisher.isAvailable {
                Text("“\(attachment.filename)” is larger than the \(limit) this server accepts. Relay can upload it to iCloud Drive and send a download link instead. Anyone with the link can download the file.")
            } else {
                Text("“\(attachment.filename)” is larger than the \(limit) this server accepts. Sign in to iCloud in System Settings to share large files as links.")
            }
        }
    }

    // MARK: - Room Upgraded Banner

    private var roomUpgradedBanner: some View {
        VStack(spacing: 6) {
            Text("This room has been upgraded.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                guard let successorRoomId, !isJoiningSuccessor else { return }
                isJoiningSuccessor = true
                Task {
                    defer { isJoiningSuccessor = false }
                    do {
                        try await client.joinRoom(roomId: successorRoomId)
                        // Wait briefly for the room list to sync so the
                        // successor appears in the sidebar before we navigate.
                        try? await Task.sleep(for: .milliseconds(500))
                        onRoomTap?(successorRoomId)
                    } catch {
                        errorReporter.report(.roomJoinFailed(error.localizedDescription))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if isJoiningSuccessor {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text("Continue the conversation")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isJoiningSuccessor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(.bar)
    }
}
