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

/// Renders a single chat message row with avatar, sender name, bubble content,
/// reply context, reactions, and emoji picker. This is the full "chrome" wrapper
/// around ``MessageBubbleContent``.
struct MessageView: View {
    /// The timeline message to render.
    let message: ObservableTimelineEvent

    /// Whether the message was sent by the local user.
    let isOutgoing: Bool

    /// Whether this message is the last in a consecutive group from the same sender.
    /// Controls avatar visibility.
    var isLastInGroup: Bool = true

    /// Whether to display the sender's name above the bubble (for the first message in a group).
    var showSenderName: Bool = false

    /// Whether the replied-to message is immediately above this one in the
    /// timeline, allowing the reply preview bubble to be omitted.
    var replyIsAdjacentAbove: Bool = false

    /// Whether to show URL previews for text messages that contain a link.
    var showURLPreviews: Bool = false

    /// Reports the bubble's global frame as it changes, so the enclosing row
    /// can anchor the reaction picker to the precise bubble (not the whole
    /// row, which would include the avatar gutter).
    var onBubbleFrameChange: ((CGRect) -> Void)? = nil

    /// Whether the reply-to message is adjacent above *and* on the same side
    /// (both incoming or both outgoing). Only in this case can we skip the
    /// preview bubble, since the user can see the original directly above.
    private var replyIsAdjacentSameSide: Bool {
        guard replyIsAdjacentAbove, let reply = message.reply else { return false }
        let replyIsOutgoing = actions.currentUserID != nil
            && reply.senderID.value == actions.currentUserID
        return isOutgoing == replyIsOutgoing
    }

    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @Environment(\.timelineActions) private var actions
    @Environment(\.swipeOffset) private var swipeOffset
    @Environment(\.swipeIsLocked) private var swipeIsLocked
    @State private var bubbleFrame: CGRect = .zero

    /// Whether reaction badges overlap the top edge, requiring extra top
    /// padding to avoid clipping.
    private var hasTopOverlay: Bool {
        !message.reactions.isEmpty
    }

    var body: some View {
        bubbleContent
            .offset(x: swipeOffset)
            .frame(maxWidth: .infinity, alignment: isOutgoing ? .trailing : .leading)
    }

    // MARK: - Bubble Content

    /// The avatar, sender name, and message bubble — everything that slides
    /// right during a swipe-to-reply gesture.
    private var bubbleContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if !isOutgoing {
                    if isLastInGroup {
                        AvatarView(
                            name: message.displayName,
                            mxcURL: message.senderAvatarURL?.value,
                            size: 28,
                            colorID: message.sender.value
                        )
                        .onTapGesture(count: 2) { actions.avatarDoubleTap(message) }
                    } else {
                        Spacer()
                            .frame(width: 28)
                    }
                }

                VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 1) {
                    if message.reply != nil {
                        if !replyIsAdjacentSameSide, let reply = message.reply {
                            ReplyPreviewBubble(reply: reply)
                        }

                        HStack(spacing: 0) {
                            if isOutgoing {
                                Spacer(minLength: 0)
                            }
                            Rectangle()
                                .fill(Color(.separatorColor))
                                .frame(width: 2, height: replyIsAdjacentSameSide ? 12 : 24)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 2)
                            if !isOutgoing {
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if showSenderName && !isOutgoing {
                        Text(message.displayName)
                            .scaledChromeFont(.caption1, weight: .medium)
                            .foregroundStyle(.secondary)
                            .padding(.leading, BubbleStyle.horizontalPadding)
                            .padding(.bottom, 2)
                    }

                    messageBubble
                }
                .frame(maxWidth: 500, alignment: isOutgoing ? .trailing : .leading)
            }
        }
    }

    // MARK: - Message Bubble

    /// The main message bubble with reaction badges, swipe action, and
    /// geometry tracking.
    private var messageBubble: some View {
        MessageBubbleContent(
            message: message,
            isOutgoing: isOutgoing,
            showURLPreviews: showURLPreviews,
            onPresentReactionPicker: {
                presentReactionPickerForBubble()
            }
        )
        .overlay(alignment: .leading) {
            if swipeOffset > 0 {
                swipeActionBar
                    .opacity(min(swipeOffset / 60, 1.0))
                    .offset(x: -swipeOffset)
            }
        }
        .overlay(alignment: isOutgoing ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
                MessageReactionBadges(
                    reactions: message.reactionGroups,
                    isOutgoing: isOutgoing,
                    coloredBubbles: coloredBubbles,
                    onToggle: { key in actions.toggleReaction(message.eventId.value, key) }
                )
            }
        }
        .padding(.top, hasTopOverlay ? 11 : 0)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            bubbleFrame = newFrame
            // Keep an open reaction picker anchored to this bubble across
            // layout changes (the timeline ignores this unless this message's
            // picker is currently open).
            actions.updateReactionPickerFrame(message.eventId.value, newFrame)
            // Report the precise bubble frame up so the row can present the
            // context-menu picker against the bubble, not the whole row.
            onBubbleFrameChange?(newFrame)
        }
        .onLongPressGesture {
            presentReactionPickerForBubble()
        }
    }

    // MARK: - Reaction Picker

    /// Presents the reaction picker overlay for this message's bubble.
    private func presentReactionPickerForBubble() {
        actions.presentReactionPicker(message.eventId.value, bubbleFrame, isOutgoing)
    }

    // MARK: - Swipe Action Bar

    /// Reply button revealed behind the bubble during a swipe-to-reply gesture.
    /// Placed as an overlay on `MessageBubbleContent` so the arrow aligns with
    /// the bubble's actual leading edge regardless of message width.
    private var swipeActionBar: some View {
        let longSwipeProgress = max(0, min((swipeOffset - 100) / 20, 1.0))
        let replyScale = 1.0 + longSwipeProgress * 0.8

        return Button("Reply", systemImage: "arrowshape.turn.up.left.fill") {
            actions.reply(message)
        }
        .labelStyle(.iconOnly)
        .scaleEffect(replyScale)
        .font(.title3)
        .foregroundStyle(longSwipeProgress > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .buttonStyle(.plain)
        .allowsHitTesting(swipeIsLocked)
    }
}

// MARK: - Previews

#Preview("Conversation") {
    VStack(spacing: 2) {
        MessageView(
            message: PreviewFixtures.event(
                "1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "Hey, check out **this link**: https://matrix.org",
                minutesAgo: 2
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "1b", sender: "@alice:matrix.org", displayName: "Alice",
                body: "It supports *italic*, **bold**, and `code`!",
                minutesAgo: 1.8,
                reactions: ["❤️": ["@me:matrix.org"], "🤖": ["@bob:matrix.org"]],
                ownReactions: ["❤️"]
            ),
            isOutgoing: false
        )
        MessageView(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org",
                body: "Nice — I'll take a look.",
                minutesAgo: 1,
                reply: PreviewFixtures.reply(
                    "1", sender: "@alice:matrix.org", displayName: "Alice",
                    body: "Hey, check out **this link**: https://matrix.org")
            ),
            isOutgoing: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "3", sender: "@bob:matrix.org", displayName: "Bob",
                body: "Hey @me:matrix.org, can you review the PR when you get a chance?",
                minutesAgo: 0.5, isHighlighted: true,
                reply: PreviewFixtures.reply(
                    "2", sender: "@me:matrix.org", displayName: "Me",
                    body: "Nice — I'll take a look.")
            ),
            isOutgoing: false,
            showSenderName: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 500)
}

#Preview("Image Message") {
    VStack(spacing: 6) {
        MessageView(
            message: PreviewFixtures.event(
                "img1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "photo.jpg",
                kind: .image(
                    body: "photo.jpg", url: "mxc://matrix.org/example",
                    info: MediaInfo(mimeType: "image/jpeg", width: 800, height: 600))
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "img2", sender: "@me:matrix.org",
                body: "screenshot.png",
                kind: .image(
                    body: "screenshot.png", url: "mxc://matrix.org/example2",
                    info: MediaInfo(mimeType: "image/png", width: 400, height: 700))
            ),
            isOutgoing: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Emoji-Only Messages") {
    VStack(spacing: 2) {
        MessageView(
            message: PreviewFixtures.event(
                "e1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "👋", minutesAgo: 1
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "e2", sender: "@me:matrix.org",
                body: "❤️🔥🎉", minutesAgo: 0.5
            ),
            isOutgoing: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Special Types") {
    VStack(spacing: 6) {
        MessageView(
            message: PreviewFixtures.event(
                "d1", sender: "@mod:matrix.org", displayName: "Moderator",
                body: "This message was deleted", kind: .redacted
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "v1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "vacation.mp4",
                kind: .video(
                    body: "vacation.mp4", url: "mxc://matrix.org/video1",
                    info: MediaInfo(
                        mimeType: "video/mp4", width: 1920, height: 1080,
                        duration: 127_000))
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "a1", sender: "@bob:matrix.org", displayName: "Bob",
                body: "voice-note.ogg",
                kind: .audio(
                    body: "voice-note.ogg", url: "mxc://matrix.org/audio1",
                    info: MediaInfo(
                        mimeType: "audio/ogg", size: 245_000, duration: 42_000))
            ),
            isOutgoing: false,
            showSenderName: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "f1", sender: "@me:matrix.org",
                body: "File",
                kind: .file(
                    body: "File", url: "mxc://matrix.org/file1",
                    info: MediaInfo(mimeType: "application/octet-stream"))
            ),
            isOutgoing: true
        )
        MessageView(
            message: PreviewFixtures.event(
                "em1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "waves hello", kind: .emote(body: "waves hello")
            ),
            isOutgoing: false,
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}
