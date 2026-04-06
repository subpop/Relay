// swiftlint:disable file_length
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

// MARK: - Media Auto-Reveal Environment

private struct MediaAutoRevealKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Controls whether media attachments in messages are shown immediately or hidden behind a tap-to-reveal overlay.
    var mediaAutoReveal: Bool {
        get { self[MediaAutoRevealKey.self] }
        set { self[MediaAutoRevealKey.self] = newValue }
    }
}

/// Renders a single chat bubble for a timeline message, with support for text, images,
/// emotes, special types (encrypted, redacted, etc.), reactions, and inline reply context.
struct MessageView: View { // swiftlint:disable:this type_body_length
    /// The timeline message to render.
    let message: TimelineMessage

    /// Whether this message is the last in a consecutive group from the same sender.
    /// Controls avatar visibility.
    var isLastInGroup: Bool = true

    /// Whether to display the sender's name above the bubble (for the first message in a group).
    var showSenderName: Bool = false

    /// Called when a reaction emoji is tapped to toggle it on the message.
    var onToggleReaction: ((String) -> Void)?

    /// Called when the inline reply preview is tapped, with the event ID to scroll to.
    var onTapReply: ((String) -> Void)?

    /// Called when the user double-taps the sender's avatar to open their profile.
    var onAvatarDoubleTap: (() -> Void)?

    /// Called when the user clicks a user mention link, with the Matrix user ID.
    var onUserTap: ((String) -> Void)?

    /// Called when the user clicks a room link, with the room ID or alias.
    var onRoomTap: ((String) -> Void)?

    /// The Matrix user ID of the signed-in user. Used to determine the bubble color
    /// of replied-to messages (outgoing vs incoming).
    var currentUserID: String?

    @Environment(\.swipeOffset) private var swipeOffset
    @State private var showEmojiPicker = false

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if message.isOutgoing {
                    Spacer(minLength: 60)
                }

                if !message.isOutgoing {
                    if isLastInGroup {
                        AvatarView(
                            name: message.displayName,
                            mxcURL: message.senderAvatarURL,
                            size: 28
                        )
                        .onTapGesture(count: 2) { onAvatarDoubleTap?() }
                    } else {
                        Spacer()
                            .frame(width: 28)
                    }
                }

                VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 1) {
                    if showSenderName && !message.isOutgoing {
                        Text(message.displayName)
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                            .padding(.bottom, 2)
                    }

                    VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: -8) {
                        if let reply = message.replyDetail {
                            let replyIsOutgoing = currentUserID != nil
                                && reply.senderID == currentUserID
                            repliedMessageBubble(reply, outgoing: replyIsOutgoing)
                                .padding(message.isOutgoing ? .trailing : .leading, 20)
                        }

                        messageContent
                            .overlay(alignment: .topTrailing) {
                                if message.isHighlighted {
                                    Image(systemName: "at")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                        .frame(width: 16, height: 16)
                                        .background(.red, in: Circle())
                                        .offset(x: 4, y: -4)
                                }
                            }
                            .padding(message.replyDetail != nil ? 2 : 0)
                            .background {
                                if message.replyDetail != nil {
                                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor))
                                }
                            }
                    }
                }
                .onLongPressGesture {
                    showEmojiPicker = true
                }
                .popover(
                    isPresented: $showEmojiPicker,
                    attachmentAnchor: .point(message.isOutgoing ? .topLeading : .topTrailing),
                    arrowEdge: .top
                ) {
                    EmojiPickerPopover { emoji in
                        onToggleReaction?(emoji)
                        showEmojiPicker = false
                    }
                }
                .background(alignment: .leading) {
                    if swipeOffset > 0 {
                        replyArrow
                            .offset(x: -swipeOffset)
                    }
                }

                if !message.isOutgoing {
                    Spacer(minLength: 60)
                }
            }

            if !message.reactions.isEmpty {
                ReactionsView(
                    reactions: message.reactions,
                    onToggle: { key in onToggleReaction?(key) }
                )
                .padding(.leading, message.isOutgoing ? 0 : 34)
            }
        }

    }

    // MARK: - Replied-To Message Bubble

    /// A muted message bubble rendered behind (and above) the main message, partially
    /// covered by it. Styled to look nearly identical to the original message, just faded.
    @ViewBuilder
    private func repliedMessageBubble(
        _ reply: TimelineMessage.ReplyDetail,
        outgoing: Bool
    ) -> some View {
        Button {
            onTapReply?(reply.eventID)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(reply.body)
                    .font(.body)
                    .foregroundStyle(outgoing ? .white : .primary)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        outgoing
                            ? Color.accentColor
                            : Color(.systemGray).opacity(0.2)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            .opacity(0.6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Message Content (dispatches to the correct content variant)

    @ViewBuilder
    private var messageContent: some View {
        if message.kind == .image, message.mediaInfo != nil {
            imageContent
        } else if message.kind == .video, message.mediaInfo != nil {
            videoContent
        } else if message.kind == .audio, message.mediaInfo != nil {
            audioContent
        } else if message.kind == .emote {
            emoteContent
        } else if message.isSpecialType {
            specialContent
        } else if isEmojiOnly {
            emojiOnlyContent
        } else {
            textContent
        }
    }

    // MARK: - Image Content

    private var imageContent: some View {
        ImageMessageView(message: message)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Video Content

    private var videoContent: some View {
        VideoMessageView(message: message)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Audio Content

    private var audioContent: some View {
        AudioMessageView(message: message)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Text Content (with markdown + links)

    private var textContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                if let resolved = htmlBody {
                    MessageTextView(
                        resolved: resolved,
                        isOutgoing: message.isOutgoing,
                        onUserTap: onUserTap,
                        onRoomTap: onRoomTap
                    )
                } else {
                    MessageTextView(
                        attributedString: markdownBody,
                        isOutgoing: message.isOutgoing,
                        onUserTap: onUserTap,
                        onRoomTap: onRoomTap
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))

            if message.isEdited {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
            }
        }
    }

    // MARK: - Emoji-Only Content

    /// Whether this text message contains only emoji (up to a reasonable count for large display).
    private var isEmojiOnly: Bool {
        message.kind == .text
            && message.formattedBody == nil
            && message.body.isEmojiOnly
            && message.body.emojiCount <= 8
    }

    private var emojiOnlyContent: some View {
        Text(message.body)
            .font(.system(size: message.body.emojiCount <= 3 ? 48 : 32))
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        Group {
            if let resolved = emoteHtmlBody {
                MessageTextView(
                    resolved: resolved,
                    isOutgoing: false,
                    onUserTap: onUserTap,
                    onRoomTap: onRoomTap
                )
            } else {
                MessageTextView(
                    attributedString: emoteBody,
                    isOutgoing: false,
                    onUserTap: onUserTap,
                    onRoomTap: onRoomTap
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Special Content (media, redacted, encrypted, etc.)

    private var specialContent: some View {
        Label {
            Text(message.body)
                .font(.callout)
        } icon: {
            Image(systemName: iconForKind)
                .font(.callout)
        }
        .foregroundStyle(foregroundForKind.opacity(0.6))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(backgroundForKind)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    private var iconForKind: String {
        switch message.kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .file: "doc"
        case .location: "location"
        case .sticker: "face.smiling"
        case .poll: "chart.bar"
        case .redacted: "trash"
        case .encrypted: "lock.fill"
        case .other: "questionmark.circle"
        default: "bubble.left"
        }
    }

    private var foregroundForKind: Color {
        switch message.kind {
        case .encrypted: .orange
        default: .primary
        }
    }

    @ViewBuilder
    private var backgroundForKind: some View {
        switch message.kind {
        case .redacted:
            Color(.systemGray).opacity(0.1)
        case .encrypted:
            Color.orange.opacity(0.1)
        default:
            Color(.systemGray).opacity(0.15)
        }
    }

    // MARK: - Body Parsing (HTML → Markdown fallback)

    /// The pre-resolved `NSAttributedString` when HTML is available, or `nil` for the Markdown path.
    private var htmlBody: NSAttributedString? {
        guard let html = message.formattedBody else { return nil }
        return Self.htmlCache.value(forKey: html) {
            MatrixHTMLParser.parse(html)
        }
    }

    private var markdownBody: AttributedString {
        Self.markdownCache.value(forKey: message.body) {
            Self.parseMarkdown(message.body)
        }
    }

    private var emoteBody: AttributedString {
        var name = AttributedString("*\(message.displayName)* ")
        name.inlinePresentationIntent = .emphasized
        return name + Self.markdownCache.value(forKey: message.body) {
            Self.parseMarkdown(message.body)
        }
    }

    /// The pre-resolved `NSAttributedString` for emote HTML, or `nil` for the Markdown path.
    private var emoteHtmlBody: NSAttributedString? {
        guard let html = message.formattedBody else { return nil }
        let cacheKey = "\(message.displayName)\0\(html)"
        return Self.emoteHtmlCache.value(forKey: cacheKey) {
            guard let parsed = MatrixHTMLParser.parse(html) else { return nil }
            // Prepend italic display name.
            let result = NSMutableAttributedString()
            let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            let italicDesc = nameFont.fontDescriptor.withSymbolicTraits(.italic)
            let italicFont = NSFont(descriptor: italicDesc, size: nameFont.pointSize) ?? nameFont
            result.append(NSAttributedString(
                string: "*\(message.displayName)* ",
                attributes: [.font: italicFont]
            ))
            result.append(parsed)
            return result
        }
    }

    // MARK: - Parse Caches

    /// LRU cache for parsed HTML bodies. Shared across all `MessageView` instances.
    private static let htmlCache = ParseCache<String, NSAttributedString?>(capacity: 128)

    /// LRU cache for parsed Markdown bodies. Shared across all `MessageView` instances.
    private static let markdownCache = ParseCache<String, AttributedString>(capacity: 128)

    /// LRU cache for parsed emote HTML bodies. Shared across all `MessageView` instances.
    private static let emoteHtmlCache = ParseCache<String, NSAttributedString?>(capacity: 64)

    private static func parseMarkdown(_ raw: String) -> AttributedString {
        var result: AttributedString
        // swiftlint:disable:next identifier_name
        if let md = try? AttributedString(
            markdown: raw,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            result = md
        } else {
            result = AttributedString(raw)
        }

        let plainString = String(result.characters)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return result
        }

        let matches = detector.matches(
            in: plainString,
            range: NSRange(plainString.startIndex..., in: plainString)
        )
        for match in matches {
            guard let urlRange = Range(match.range, in: plainString),
                  let attrRange = Range(urlRange, in: result) else { continue }
            if result[attrRange].link == nil {
                result[attrRange].link = match.url
            }
        }
        return result
    }

    // MARK: - Reply Arrow

    private var replyArrow: some View {
        let triggerThreshold: CGFloat = 80
        let progress = min(swipeOffset / triggerThreshold, 1.0)

        return Image(systemName: "arrowshape.turn.up.left.fill")
            .font(.title)
            .foregroundStyle(.secondary)
            .scaleEffect(0.4 + 0.6 * progress)
            .opacity(Double(progress))
    }

    // MARK: - Bubble Color

    private var bubbleColor: Color {
        message.isOutgoing ? .accentColor : Color(.unemphasizedSelectedContentBackgroundColor)
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
                    )
                ]
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "2",
                senderID: "@me:matrix.org",
                body: "Nice — I'll take a look.",
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
            ),
            currentUserID: "@me:matrix.org"
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
                    body: "Nice — I'll take a look."
                )
            ),
            showSenderName: true,
            currentUserID: "@me:matrix.org"
        )
    }
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
