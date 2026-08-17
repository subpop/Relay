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

/// Groups the three `@State` properties that describe the currently open
/// reaction picker into a single value, reducing the number of independent
/// `@State` declarations in ``TimelineView``.
struct ReactionPickerState: Equatable {
    /// The event ID of the message whose reaction picker is open, or `nil`.
    var messageId: String?
    /// The global-coordinate frame of the bubble the picker is anchored to.
    var bubbleFrame: CGRect = .zero
    /// Whether the anchored message is outgoing (determines picker alignment).
    var isOutgoing = false
}

/// The reply full-screen preview overlay shown when the compose bar is in
/// reply mode. Tapping the backdrop dismisses the preview.
struct ReplyPreviewOverlay: View {
    let compose: ComposeViewModel
    let actions: TimelineActions
    let readOnly: Bool

    var body: some View {
        if !readOnly, let reply = compose.replyingTo {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                            compose.cancelReply()
                        }
                    }

                MessageView(
                    message: reply,
                    isLastInGroup: true,
                    showSenderName: !reply.isOutgoing
                )
                .environment(\.timelineActions, actions)
                .allowsHitTesting(false)
                .padding(.horizontal, 16)
            }
            .transition(.opacity)
        }
    }
}

/// The file drop target overlay shown when files are dragged over the timeline.
struct DropTargetOverlay: View {
    let readOnly: Bool
    let isTargeted: Bool

    var body: some View {
        if !readOnly, isTargeted {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .ignoresSafeArea()

                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text("Drop files to attach")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// The reaction picker overlay, shown anchored to a message bubble.
struct TimelineReactionPickerOverlay: View {
    @Binding var state: ReactionPickerState
    let actions: TimelineActions

    var body: some View {
        if state.messageId != nil {
            ReactionPickerOverlay(
                bubbleFrame: state.bubbleFrame,
                isOutgoing: state.isOutgoing,
                onSelect: { emoji in
                    if let messageId = state.messageId {
                        RecentEmojiStore.shared.recordUsage(emoji)
                        actions.toggleReaction(messageId, emoji)
                    }
                },
                onDismiss: {
                    withAnimation(.easeOut(duration: 0.15)) {
                        state.messageId = nil
                    }
                }
            )
        }
    }
}
