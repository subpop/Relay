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

import OSLog
import RelayInterface
import SwiftUI

private let logger = Logger(subsystem: "Relay", category: "MessageView.Translate")

/// Renders a single chat message row with avatar, sender name, bubble content,
/// reply context, reactions, and emoji picker. This is the full "chrome" wrapper
/// around ``MessageBubbleContent``.
///
/// For contexts that only need the bubble content without interactive chrome
/// (e.g. pinned messages, search results), use ``MessageBubbleContent`` directly.
struct MessageView: View { // swiftlint:disable:this type_body_length
    /// The timeline message to render.
    let message: TimelineMessage

    /// Whether this message is the last in a consecutive group from the same sender.
    /// Controls avatar visibility.
    var isLastInGroup: Bool = true

    /// Whether to display the sender's name above the bubble (for the first message in a group).
    var showSenderName: Bool = false

    /// Whether the replied-to message is immediately above this one in the
    /// timeline, allowing the reply preview bubble to be omitted.
    var replyIsAdjacentAbove: Bool = false

    /// Whether the reply-to message is adjacent above *and* on the same side
    /// (both incoming or both outgoing). Only in this case can we skip the
    /// preview bubble, since the user can see the original directly above.
    private var replyIsAdjacentSameSide: Bool {
        guard replyIsAdjacentAbove, let reply = message.replyDetail else { return false }
        let replyIsOutgoing = actions.currentUserID != nil
            && reply.senderID == actions.currentUserID
        return message.isOutgoing == replyIsOutgoing
    }

    /// Per-message translation state. When `.translated`, the rendered
    /// body and parsed Markdown/HTML come from the translation; in all
    /// other states the original message body is used. The view also
    /// shows a translate-glyph badge when `.translated` or `.loading`.
    var translation: MessageTranslationState = .idle

    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @Environment(\.timelineActions) private var actions
    @Environment(\.swipeOffset) private var swipeOffset
    @Environment(\.swipeIsLocked) private var swipeIsLocked
    @State private var bubbleFrame: CGRect = .zero

    /// Whether reaction badges overlap the top edge, requiring extra top
    /// padding to avoid clipping.
    private var hasTopOverlay: Bool {
        !message.reactions.isEmpty || showsTranslationBadge
    }

    var body: some View {
        bubbleContent
            .offset(x: swipeOffset)
            .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
    }

    // MARK: - Bubble Content

    /// The avatar, sender name, and message bubble — everything that slides
    /// right during a swipe-to-reply gesture.
    private var bubbleContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if !message.isOutgoing {
                    if isLastInGroup {
                        AvatarView(
                            name: message.displayName,
                            mxcURL: message.senderAvatarURL,
                            size: 28
                        )
                        .onTapGesture(count: 2) { actions.avatarDoubleTap(message) }
                    } else {
                        Spacer()
                            .frame(width: 28)
                    }
                }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                    if message.replyDetail != nil {
                        if !replyIsAdjacentSameSide, let reply = message.replyDetail {
                            ReplyPreviewBubble(reply: reply)
                        }

                        HStack(spacing: 0) {
                            if message.isOutgoing {
                                Spacer(minLength: 0)
                            }
                            Rectangle()
                                .fill(Color(.separatorColor))
                                .frame(width: 2, height: replyIsAdjacentSameSide ? 12 : 24)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 2)
                            if !message.isOutgoing {
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    if showSenderName && !message.isOutgoing {
                        Text(message.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.leading, BubbleStyle.horizontalPadding)
                            .padding(.bottom, 2)
                    }

                    messageBubble
                }
                .frame(maxWidth: 500, alignment: message.isOutgoing ? .trailing : .leading)
            }
        }
    }

    // MARK: - Message Bubble

    /// The main message bubble with reaction badges, swipe action, and
    /// geometry tracking.
    private var messageBubble: some View {
        MessageBubbleContent(
            message: message,
            translation: translation,
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
        .overlay(alignment: message.isOutgoing ? .topLeading : .topTrailing) {
            if !message.reactions.isEmpty {
                MessageReactionBadges(
                    reactions: message.reactions,
                    isOutgoing: message.isOutgoing,
                    coloredBubbles: coloredBubbles,
                    onToggle: { key in actions.toggleReaction(message.eventID, key) }
                )
                .offset(
                    x: -4,
                    y: -11
                )
            }
        }
        // Translation glyph on the corner opposite the reaction badges so
        // the two never collide.
        .overlay(alignment: message.isOutgoing ? .topTrailing : .topLeading) {
            if showsTranslationBadge {
                translationBadge
                    .offset(x: message.isOutgoing ? 6 : -6, y: -11)
            }
        }
        .padding(.top, hasTopOverlay ? 11 : 0)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named("timeline"))
        } action: { newFrame in
            bubbleFrame = newFrame
        }
        .onLongPressGesture {
            presentReactionPickerForBubble()
        }
    }

    // MARK: - Reaction Picker

    /// Presents the reaction picker overlay for this message's bubble.
    private func presentReactionPickerForBubble() {
        actions.presentReactionPicker(message.eventID, bubbleFrame, message.isOutgoing)
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

    // MARK: - Translation Badge

    /// Whether the corner badge should be shown for translation state.
    /// Only `.translated` and `.loading` get a badge; `.idle` and
    /// `.failed` are visually invisible (failures surface as a toast).
    private var showsTranslationBadge: Bool {
        switch translation {
        case .translated, .loading: true
        case .idle, .failed: false
        }
    }

    /// Translation badge — small `translate` glyph over a tinted disc.
    /// Loading state swaps the glyph for a spinner so the user sees
    /// progress.
    @ViewBuilder
    private var translationBadge: some View {
        switch translation {
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .frame(width: 16, height: 16)
                .background(.tint, in: Circle())
        default:
            Image(systemName: "translate")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(.tint, in: Circle())
        }
    }
}

// MARK: - Previews

#Preview("Conversation") {
    VStack(spacing: 2) {
        MessageView(
            message: TimelineMessage(
                id: "1",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "Hey, check out **this link**: https://matrix.org",
                timestamp: .now.addingTimeInterval(-120),
                isOutgoing: false
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "1b",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "It supports *italic*, **bold**, and `code`!",
                timestamp: .now.addingTimeInterval(-110),
                isOutgoing: false,
                reactions: [
                    .init(
                        key: "\u{2764}\u{FE0F}", count: 1,
                        senderIDs: ["@me:matrix.org"],
                        highlightedByCurrentUser: true
                    ),
                    .init(
                        key: "🤖", count: 1,
                        senderIDs: ["@bob:matrix.org"],
                        highlightedByCurrentUser: false
                    ),
                    .init(
                        key: "🦞", count: 1,
                        senderIDs: ["@bob:matrix.org"],
                        highlightedByCurrentUser: false
                    ),
                    .init(
                        key: "🤡", count: 1,
                        senderIDs: ["@bob:matrix.org"],
                        highlightedByCurrentUser: false
                    )
                ]
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "1c",
                senderID: "@alice:matrix.org",
                senderDisplayName: "Alice",
                body: "",
                formattedBody: "<blockquote>Per your email:\n<blockquote>When is the schedule release date?</blockquote>\n</blockquote>\nTuesday",
                timestamp: .now.addingTimeInterval(-100),
                isOutgoing: false,
                reactions: [],
            ),
        )
        MessageView(
            message: TimelineMessage(
                id: "2",
                senderID: "@me:matrix.org",
                body: "Nice \u{2014} I'll take a look.",
                timestamp: .now.addingTimeInterval(-60),
                isOutgoing: true,
                reactions: [
                    .init(
                        key: "\u{1F44D}", count: 2,
                        senderIDs: ["@alice:matrix.org", "@bob:matrix.org"],
                        highlightedByCurrentUser: false
                    ),
                    .init(
                        key: "\u{2764}\u{FE0F}", count: 1,
                        senderIDs: ["@alice:matrix.org"],
                        highlightedByCurrentUser: false
                    ),
                    .init(
                        key: "\u{1F389}", count: 1,
                        senderIDs: ["@me:matrix.org"],
                        highlightedByCurrentUser: true
                    )
                ],
                replyDetail: .init(
                    eventID: "1",
                    senderID: "@alice:matrix.org",
                    senderDisplayName: "Alice",
                    body: "Hey, check out **this link**: https://matrix.org"
                )
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "3",
                senderID: "@bob:matrix.org",
                senderDisplayName: "Bob",
                body: "Hey @me:matrix.org, can you review the PR when you get a chance?",
                timestamp: .now.addingTimeInterval(-30),
                isOutgoing: false,
                isHighlighted: true,
                replyDetail: .init(
                    eventID: "2",
                    senderID: "@me:matrix.org",
                    senderDisplayName: "Me",
                    body: "Nice \u{2014} I'll take a look."
                )
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "4",
                senderID: "@me:matrix.org",
                body: "Sure. It's up on [GitHub](https://github.com).",
                timestamp: .now.addingTimeInterval(-20),
                isOutgoing: true,
                reactions: [],
                replyDetail: nil
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "5",
                senderID: "@alice:matrix.org",
                body: "> Sure. It's up on GitHub.\nWhich project?",
                formattedBody: "<blockquote>Sure. It's up on GitHub.</blockquote>\nWhich project?",
                timestamp: .now.addingTimeInterval(-10),
                isOutgoing: false,
                reactions: [],
                replyDetail: nil
            )
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 500)
}

#Preview("Image Message") {
    VStack(spacing: 6) {
        MessageView(
            message: TimelineMessage(
                id: "img1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Image", timestamp: .now, isOutgoing: false, kind: .image,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/example",
                    filename: "photo.jpg",
                    mimetype: "image/jpeg",
                    width: 800, height: 600
                )
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "img2", senderID: "@me:matrix.org",
                body: "Check this out", timestamp: .now, isOutgoing: true, kind: .image,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/example2",
                    filename: "screenshot.png",
                    mimetype: "image/png",
                    width: 400, height: 700,
                    caption: "Check this out"
                )
            )
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Emoji-Only Messages") {
    VStack(spacing: 2) {
        MessageView(
            message: TimelineMessage(
                id: "e1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "\u{1F44B}", timestamp: .now.addingTimeInterval(-60), isOutgoing: false
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "e2", senderID: "@me:matrix.org",
                body: "\u{2764}\u{FE0F}\u{1F525}\u{1F389}", timestamp: .now.addingTimeInterval(-30), isOutgoing: true
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "e3", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                body: "\u{1F602}\u{1F602}\u{1F602}\u{1F602}\u{1F602}", timestamp: .now, isOutgoing: false
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "e4", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Hello \u{1F44B}", timestamp: .now, isOutgoing: false
            ),
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}

#Preview("Special Types") {
    VStack(spacing: 6) {
        MessageView(
            message: TimelineMessage(
                id: "d1", senderID: "@mod:matrix.org", senderDisplayName: "Moderator",
                body: "This message was deleted", timestamp: .now, isOutgoing: false, kind: .redacted
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "e1", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                body: "Waiting for encryption key", timestamp: .now, isOutgoing: false, kind: .encrypted
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "v1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "vacation.mp4", timestamp: .now, isOutgoing: false, kind: .video,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/video1",
                    filename: "vacation.mp4",
                    mimetype: "video/mp4",
                    width: 1920, height: 1080,
                    duration: 127
                )
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "a1", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                body: "voice-note.ogg", timestamp: .now, isOutgoing: false, kind: .audio,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/audio1",
                    filename: "voice-note.ogg",
                    mimetype: "audio/ogg",
                    size: 245_000,
                    duration: 42
                )
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "a2", senderID: "@me:matrix.org",
                body: "podcast-clip.mp3", timestamp: .now, isOutgoing: true, kind: .audio,
                mediaInfo: .init(
                    mxcURL: "mxc://matrix.org/audio2",
                    filename: "podcast-clip.mp3",
                    mimetype: "audio/mpeg",
                    size: 3_200_000,
                    duration: 185
                )
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "f1", senderID: "@me:matrix.org",
                body: "File", timestamp: .now, isOutgoing: true, kind: .file
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "em1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "waves hello", timestamp: .now, isOutgoing: false, kind: .emote
            ),
            showSenderName: true
        )
    }
    .padding()
    .frame(width: 500)
}
