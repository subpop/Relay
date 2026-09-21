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
import MatrixKit
import SwiftUI

/// Renders the inner content of a message bubble, dispatching to the appropriate
/// content variant based on the message kind. This view applies bubble styling
/// (background, shape, padding) consistently across all message types.
///
/// ``MessageBubbleContent`` is the reusable bubble core, composed into
/// ``MessageView`` (which adds avatar, sender name, reactions, and interactive
/// chrome).
struct MessageBubbleContent: View {
    /// The timeline message to render.
    let message: ObservableTimelineEvent

    /// Whether the message was sent by the local user.
    let isOutgoing: Bool

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
        } else if case .emote = message.kind {
            emoteContent
        } else if case .sticker = message.kind, message.mediaDownload != nil {
            // Stickers render as images when downloadable; without a URL
            // they fall through to the special-content placeholder below.
            imageContent
        } else if message.kind.isSpecialType {
            specialContent
        } else if isEmojiOnly {
            emojiOnlyContent
        } else {
            textContent
        }
    }

    // MARK: - Text Content

    private var style: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: message.sender.value,
            coloredBubbles: coloredBubbles)
    }

    private var textContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                MessageTextView(
                    attributedString: parsedBody,
                    isOutgoing: style.usesWhiteText,
                    onUserTap: { actions.userTap($0) },
                    onRoomTap: actions.roomTap,
                    contextMessage: onPresentReactionPicker != nil ? message : nil,
                    isOutgoingMessage: isOutgoing,
                    onMessageContextAction: { actions.contextAction($0) },
                    onPresentReactionPicker: onPresentReactionPicker,
                    permissions: actions.permissions,
                    highlightedUserId: message.highlightedMentionUserId?.value,
                    highlightKeywords: message.highlightKeywords
                )
                .padding(.horizontal, BubbleStyle.horizontalPadding)
                .padding(.vertical, BubbleStyle.verticalPadding)

                if showURLPreviews, case .text = message.kind,
                   let url = URLPreviewExtractor.firstPreviewURL(in: message.body) {
                    LinkPreviewView(url: url, isOutgoing: isOutgoing, messageID: message.eventId.value)
                        .id(url)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .background(style.backgroundColor)
            .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
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
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            ImageMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Video Content

    private var videoContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            VideoMessageView(message: message)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Audio Content

    private var audioContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            AudioMessageView(message: message, isOutgoing: isOutgoing)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - File Content

    private var fileContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            FileMessageView(message: message, isOutgoing: isOutgoing)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Emoji-Only Content

    /// Whether this text message contains only emoji (up to a reasonable count
    /// for large display).
    private var isEmojiOnly: Bool {
        if case .text = message.kind,
           message.formattedBody == nil,
           message.body.isEmojiOnly,
           message.body.emojiCount <= 8 {
            return true
        }
        return false
    }

    private var emojiOnlyContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            Text(message.body)
                .font(.system(size: message.body.emojiCount <= 3 ? 72 : 48))

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            MessageTextView(
                attributedString: emoteParsedBody,
                isOutgoing: false,
                onUserTap: { actions.userTap($0) },
                onRoomTap: actions.roomTap,
                contextMessage: onPresentReactionPicker != nil ? message : nil,
                isOutgoingMessage: isOutgoing,
                onMessageContextAction: { actions.contextAction($0) },
                onPresentReactionPicker: onPresentReactionPicker,
                permissions: actions.permissions,
                highlightedUserId: message.highlightedMentionUserId?.value,
                highlightKeywords: message.highlightKeywords
            )
            .padding(.horizontal, BubbleStyle.horizontalPadding)
            .padding(.vertical, BubbleStyle.verticalPadding)
            .background(BubbleStyle.emote.backgroundColor)
            .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Special Content (redacted, location, poll, etc.)

    private var specialContent: some View {
        let specialStyle = BubbleStyle.special(kind: message.kind)
        return VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
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

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    private var iconForKind: String {
        switch message.kind {
        case .image: "photo"
        case .video: "play.rectangle"
        case .audio: "waveform"
        case .file: "doc"
        case .location, .liveLocation: "location"
        case .sticker: "face.smiling"
        case .poll: "chart.bar"
        case .redacted: "trash"
        case .unableToDecrypt: "lock"
        case .state, .profileChange, .callEvent: "info.circle"
        case .unknown: "questionmark.circle"
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
            message: PreviewFixtures.event(
                "1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "Hey, how's the project going?"
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org",
                body: "Going well! Just pushed a fix."
            ),
            isOutgoing: true
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "3", sender: "@me:matrix.org",
                body: "This one was edited", isEdited: true
            ),
            isOutgoing: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Send Failures") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "1", sender: "@me:matrix.org",
                body: "This text failed to send",
                sendState: .failed("Generic API error")
            ),
            isOutgoing: true
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org",
                body: "photo.jpg",
                kind: .image(
                    body: "photo.jpg", url: "mxc://matrix.org/example",
                    info: MediaInfo(mimeType: "image/jpeg", width: 800, height: 600)),
                sendState: .failed("Media content is no longer available")
            ),
            isOutgoing: true
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "3", sender: "@me:matrix.org",
                body: "dances", kind: .emote(body: "dances"),
                sendState: .failed("A user's verification status changed")
            ),
            isOutgoing: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Special Types") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "1", sender: "@mod:matrix.org", displayName: "Moderator",
                body: "This message was deleted", kind: .redacted
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@bob:matrix.org", displayName: "Bob",
                body: "", kind: .unableToDecrypt
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "3", sender: "@carol:matrix.org", displayName: "Carol",
                body: "Sticker",
                kind: .sticker(body: "Sticker", url: nil, info: nil)
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "4", sender: "@alice:matrix.org", displayName: "Alice",
                body: "report.pdf",
                kind: .file(
                    body: "report.pdf", url: "mxc://matrix.org/file1",
                    info: MediaInfo(mimeType: "application/pdf", size: 1_250_000))
            ),
            isOutgoing: false
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Link Preview") {
    VStack(spacing: 6) {
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "Check out https://matrix.org"
            ),
            isOutgoing: false,
            showURLPreviews: true
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org",
                body: "Take a look at https://matrix.org"
            ),
            isOutgoing: true,
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
            message: PreviewFixtures.event(
                "1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "waves hello", kind: .emote(body: "waves hello")
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org", displayName: "Me",
                body: "waves back", kind: .emote(body: "waves back")
            ),
            isOutgoing: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}
