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

import SwiftUI

// MARK: - Preview Helpers

/// A SwiftUI-native timeline view used for previews. The NSTableView-backed
/// timeline doesn't render in Xcode's static preview snapshots, so previews
/// use a ScrollView + ForEach fallback to display messages.
struct PreviewTimeline: View {
    let viewModel: PreviewTimelineViewModel
    let showUnreadMarker: Bool

    init(_ viewModel: PreviewTimelineViewModel, showUnreadMarker: Bool = false) {
        self.viewModel = viewModel
        self.showUnreadMarker = showUnreadMarker
    }

    var body: some View {
        let rows = TimelineView.buildRows(for: viewModel.messages, hasReachedStart: true)
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(rows) { row in
                    TimelineRowView(
                        row: row,
                        isNewlyAppended: false,
                        showUnreadMarker: showUnreadMarker,
                        firstUnreadMessageId: viewModel.firstUnreadMessageId,
                        highlightedMessageId: nil,
                        showURLPreviews: true,
                        currentUserID: "@me:matrix.org",
                        onToggleReaction: { _, _ in },
                        onTapReply: { _ in },
                        onReply: { _ in },
                        onAvatarDoubleTap: { _ in },
                        onUserTap: { _ in },
                        onRoomTap: nil,
                        onAppear: { _ in },
                        onContextAction: { _ in },
                        onHighlightDismissed: {}
                    )
                }
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                TextField("Message", text: .constant(""))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .overlay {
            if !viewModel.isLoading && viewModel.messages.isEmpty {
                ContentUnavailableView(
                    "No Messages Yet",
                    systemImage: "text.bubble",
                    description: Text("Send a message to get the conversation started.")
                )
            }
        }
    }
}

#Preview("Messages") {
    PreviewTimeline(PreviewTimelineViewModel())
        .frame(width: 500, height: 600)
}

#Preview("Unread Marker") {
    PreviewTimeline(
        PreviewTimelineViewModel(firstUnreadMessageId: "8"),
        showUnreadMarker: true
    )
    .frame(width: 500, height: 600)
}

#Preview("Typing Indicator") {
    // Typing indicator is an overlay on the NSTableView, so we show it
    // separately here since the preview uses a ScrollView fallback.
    PreviewTimeline(PreviewTimelineViewModel())
        .frame(width: 500, height: 600)
}

#Preview("Empty") {
    PreviewTimeline(PreviewTimelineViewModel(messages: []))
        .frame(width: 500, height: 450)
}
