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
        VStack(spacing: 0) {
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
                }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
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
