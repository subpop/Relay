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

import AppKit
import RelayInterface
import SwiftUI

/// Renders the inner content of a message bubble, dispatching to the appropriate
/// content variant based on the message kind. This view applies bubble styling
/// (background, shape, padding) consistently across all message types.
///
/// ``MessageBubbleContent`` is the reusable core of message rendering. It can be
/// composed into ``MessageView`` (which adds avatar, sender name, reactions, and
/// interactive chrome) or used standalone in contexts like ``PinnedMessagesView``
/// where only the bubble content is needed.
struct MessageBubbleContent: View {
    /// The timeline message to render.
    let message: TimelineMessage

    /// Whether to show URL previews for text messages that contain a link.
    var showURLPreviews: Bool = false

    /// Called to present the emoji reaction picker from within rich text context menus.
    var onPresentReactionPicker: (() -> Void)?

    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @Environment(\.timelineActions) private var actions

    var body: some View {
        content
    }

    // MARK: - Content Dispatch

    @ViewBuilder
    private var content: some View {
        if case .image = message.kind {
            imageContent
        } else if case .video = message.kind {
            videoContent
        } else if case .audio = message.kind {
            audioContent
        } else if case .file = message.kind {
            fileContent
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

    // MARK: - Text Content

    private var style: BubbleStyle {
        .message(for: message, coloredBubbles: coloredBubbles)
    }

    private var textContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                MessageTextView(
                    attributedString: parsedBody,
                    isOutgoing: style.usesWhiteText,
                    onUserTap: { actions.userTap($0) },
                    onRoomTap: actions.roomTap,
                    contextMessage: onPresentReactionPicker != nil ? message : nil,
                    onMessageContextAction: { actions.contextAction($0) },
                    onPresentReactionPicker: onPresentReactionPicker,
                    permissions: actions.permissions,
                    highlightedUserId: message.highlightedMentionUserId,
                    highlightKeywords: message.highlightKeywords
                )
                .padding(.horizontal, BubbleStyle.horizontalPadding)
                .padding(.vertical, BubbleStyle.verticalPadding)

                if showURLPreviews, message.kind == .text,
                   let url = URLPreviewExtractor.firstPreviewURL(in: message.body) {
                    LinkPreviewView(url: url, isOutgoing: message.isOutgoing, messageID: message.id)
                        .id(url)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .background(style.backgroundColor)
            .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            } else if message.isEdited {
                Text("edited")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, BubbleStyle.horizontalPadding)
            }
        }
    }

    private func sendFailedLabel(_ reason: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle")
            Text(reason)
        }
        .font(.caption2)
        .foregroundStyle(.red)
        .padding(.horizontal, BubbleStyle.horizontalPadding)
    }

    // MARK: - Image Content

    private var imageContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            ImageMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Video Content

    private var videoContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            VideoMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Audio Content

    private var audioContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            AudioMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - File Content

    private var fileContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            FileMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Emoji-Only Content

    /// Whether this text message contains only emoji (up to a reasonable count
    /// for large display).
    private var isEmojiOnly: Bool {
        message.kind == .text
            && message.formattedBody == nil
            && message.body.isEmojiOnly
            && message.body.emojiCount <= 8
    }

    private var emojiOnlyContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(message.body)
                .font(.system(size: message.body.emojiCount <= 3 ? 72 : 48))

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            MessageTextView(
                attributedString: emoteParsedBody,
                isOutgoing: false,
                onUserTap: { actions.userTap($0) },
                onRoomTap: actions.roomTap,
                contextMessage: onPresentReactionPicker != nil ? message : nil,
                onMessageContextAction: { actions.contextAction($0) },
                onPresentReactionPicker: onPresentReactionPicker,
                permissions: actions.permissions,
                highlightedUserId: message.highlightedMentionUserId,
                highlightKeywords: message.highlightKeywords
            )
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, BubbleStyle.verticalPadding)
            .background(BubbleStyle.emote.backgroundColor)
            .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Special Content (redacted, encrypted, file, etc.)

    private var specialContent: some View {
        let specialStyle = BubbleStyle.special(kind: message.kind)
        return VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            Label {
                Text(message.body)
                    .font(.callout)
            } icon: {
                Image(systemName: iconForKind)
                    .font(.callout)
            }
            .foregroundStyle(specialStyle.foregroundStyle)
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, BubbleStyle.verticalPadding)
            .background(specialStyle.backgroundColor)
            .clipShape(BubbleStyle.shape)

            if case .sendingFailed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    private var iconForKind: String {
        switch message.kind {
        case .image(_): "photo"
        case .video(_): "play.rectangle"
        case .audio(_): "waveform"
        case .file(_): "doc"
        case .location: "location"
        case .sticker(_): "face.smiling"
        case .poll: "chart.bar"
        case .redacted: "trash"
        case .encrypted: "lock.fill"
        case .other: "questionmark.circle"
        default: "bubble.left"
        }
    }

    // MARK: - Body Parsing (HTML -> Markdown fallback)

    /// The parsed message body as an `NSAttributedString`. Prefers `formatted_body`
    /// (HTML) when available, falling back to inline Markdown parsing of `body`.
    private var parsedBody: NSAttributedString {
        if let html = message.formattedBody {
            let cached = Self.htmlCache.value(forKey: html) {
                NSAttributedString(matrixHTML: html)
            }
            if let result = cached { return result }
        }
        return Self.markdownCache.value(forKey: message.body) {
            NSAttributedString(matrixMarkdown: message.body)
        }
    }

    /// The parsed emote body as an `NSAttributedString`. Prepends an italic
    /// display name. Prefers `formatted_body` (HTML) when available.
    private var emoteParsedBody: NSAttributedString {
        if let html = message.formattedBody {
            let cacheKey = "\(message.displayName)\0\(html)"
            let cached = Self.emoteHtmlCache.value(forKey: cacheKey) {
                guard let parsed = NSAttributedString(matrixHTML: html) else { return nil }
                let emoteResult = NSMutableAttributedString()
                let nameFont = MessageTextScale.baseFont
                let italicDesc = nameFont.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: nameFont.pointSize) ?? nameFont
                emoteResult.append(NSAttributedString(
                    string: "*\(message.displayName)* ",
                    attributes: [.font: italicFont]
                ))
                emoteResult.append(parsed)
                return emoteResult
            }
            if let result = cached { return result }
        }
        // Markdown fallback with italic name prefix.
        let nameFont = MessageTextScale.baseFont
        let italicDesc = nameFont.fontDescriptor.withSymbolicTraits(.italic)
        let italicFont = NSFont(descriptor: italicDesc, size: nameFont.pointSize) ?? nameFont
        let result = NSMutableAttributedString(
            string: "*\(message.displayName)* ",
            attributes: [.font: italicFont]
        )
        result.append(NSAttributedString(matrixMarkdown: message.body))
        return result
    }
}
// MARK: - Previews

#Preview("Text") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: TimelineMessage(
                id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Hey, how's the project going?",
                timestamp: .now, isOutgoing: false
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "2", senderID: "@me:matrix.org",
                body: "Going well! Just pushed a fix.",
                timestamp: .now, isOutgoing: true
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "3", senderID: "@me:matrix.org",
                body: "This one was edited",
                timestamp: .now, isOutgoing: true, isEdited: true
            )
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Send Failures") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: TimelineMessage(
                id: "1", senderID: "@me:matrix.org",
                body: "This text failed to send",
                timestamp: .now, isOutgoing: true,
                sendState: .sendingFailed("Generic API error")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "2", senderID: "@me:matrix.org",
                body: "Image", timestamp: .now, isOutgoing: true,
                kind: .image(.init(
                    mxcURL: "mxc://matrix.org/example",
                    filename: "photo.jpg", mimetype: "image/jpeg",
                    width: 800, height: 600
                )),
                sendState: .sendingFailed("Media content is no longer available")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "3", senderID: "@me:matrix.org",
                body: "vacation.mp4", timestamp: .now, isOutgoing: true,
                kind: .video(.init(
                    mxcURL: "mxc://matrix.org/video1",
                    filename: "vacation.mp4", mimetype: "video/mp4",
                    width: 1920, height: 1080, duration: 127
                )),
                sendState: .sendingFailed("Unverified devices in this room")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "4", senderID: "@me:matrix.org",
                body: "voice-note.ogg", timestamp: .now, isOutgoing: true,
                kind: .audio(.init(
                    mxcURL: "mxc://matrix.org/audio1",
                    filename: "voice-note.ogg", mimetype: "audio/ogg",
                    size: 245_000, duration: 42
                )),
                sendState: .sendingFailed("Session verification required")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "5", senderID: "@me:matrix.org",
                body: "\u{1F44B}", timestamp: .now, isOutgoing: true,
                sendState: .sendingFailed("Generic API error")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "6", senderID: "@me:matrix.org",
                body: "dances", timestamp: .now, isOutgoing: true, kind: .emote,
                sendState: .sendingFailed("A user's verification status changed")
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "7", senderID: "@me:matrix.org",
                body: "report.pdf", timestamp: .now, isOutgoing: true,
                kind: .file(.init(
                    mxcURL: "mxc://matrix.org/file2",
                    filename: "report.pdf", mimetype: "application/pdf",
                    size: 1_250_000
                )),
                sendState: .sendingFailed("Invalid file type: application/pdf")
            )
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Special Types") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: TimelineMessage(
                id: "1", senderID: "@mod:matrix.org", senderDisplayName: "Moderator",
                body: "This message was deleted",
                timestamp: .now, isOutgoing: false, kind: .redacted
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "2", senderID: "@bob:matrix.org", senderDisplayName: "Bob",
                body: "Waiting for encryption key",
                timestamp: .now, isOutgoing: false, kind: .encrypted
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "3", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "report.pdf",
                timestamp: .now, isOutgoing: false,
                kind: .file(.init(
                    mxcURL: "mxc://matrix.org/file1",
                    filename: "report.pdf", mimetype: "application/pdf",
                    size: 1_250_000
                ))
            )
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Link Preview") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: TimelineMessage(
                id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Check out https://matrix.org",
                timestamp: .now, isOutgoing: false
            ),
            showURLPreviews: true
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "2", senderID: "@me:matrix.org",
                body: "Take a look at https://matrix.org",
                timestamp: .now, isOutgoing: true
            ),
            showURLPreviews: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Emote") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: TimelineMessage(
                id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "waves hello",
                timestamp: .now, isOutgoing: false, kind: .emote
            )
        )
        MessageBubbleContent(
            message: TimelineMessage(
                id: "2", senderID: "@me:matrix.org", senderDisplayName: "Me",
                body: "waves back",
                timestamp: .now, isOutgoing: true, kind: .emote
            )
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

