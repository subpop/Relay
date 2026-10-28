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

    /// Upload progress (0 to 1) when this message is a locally-staged
    /// attachment still uploading, or nil otherwise.
    var uploadProgress: Double? = nil

    /// Diagnostic information when this encrypted event cannot be decrypted.
    var decryptionFailure: RoomCrypto.DecryptionFailure? = nil

    /// Called to present the emoji reaction picker from within rich text context menus.
    var onPresentReactionPicker: (() -> Void)?

    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false
    @AppStorage(OutgoingBubbleColor.userDefaultsKey) private var outgoingBubbleColor = OutgoingBubbleColor.accent

    /// Mirrors ``MessageTextScale``'s persisted value purely so this view
    /// re-evaluates on a text-zoom step. ``TimelineRowView`` is `Equatable`
    /// and its `==` doesn't consider the scale, so without reading it here
    /// directly a zoom step would never re-render the bubble body — the same
    /// reason ``scaledChromeFont`` reads the scale via `@AppStorage` rather
    /// than through ``MessageTextScale/scale`` itself.
    @AppStorage(MessageTextScale.userDefaultsKey) private var textScale = Double(MessageTextScale.defaultScale)

    @State private var isShowingFullMessage = false

    @Environment(\.timelineActions) private var actions
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content
    }

    /// Outgoing bubbles with a light background color (yellow, cyan) render
    /// their content in the light appearance so dynamic text colors resolve
    /// to black, even when the system is in dark appearance.
    private var bubbleColorScheme: ColorScheme {
        isOutgoing && !style.usesWhiteText ? .light : colorScheme
    }

    // MARK: - Content Dispatch

    @ViewBuilder
    private var content: some View {
        if case .image = message.kind {
            imageContent
        } else if case .video = message.kind {
            videoContent
        } else if case .gallery(let body, let items) = message.kind {
            galleryContent(body: body, items: items)
        } else if case .audio = message.kind {
            audioContent
                .environment(\.colorScheme, bubbleColorScheme)
        } else if case .file = message.kind {
            fileContent
                .environment(\.colorScheme, bubbleColorScheme)
        } else if case .emote = message.kind {
            emoteContent
        } else if case .sticker = message.kind, message.mediaDownload != nil {
            // Stickers render when downloadable; without a URL they fall
            // through to the special-content placeholder below.
            stickerContent
        } else if case .poll(let poll) = message.kind {
            pollContent(poll)
                .environment(\.colorScheme, bubbleColorScheme)
        } else if message.kind.isSpecialType {
            specialContent
        } else if isEmojiOnly {
            emojiOnlyContent
        } else {
            textContent
                .environment(\.colorScheme, bubbleColorScheme)
        }
    }

    // MARK: - Text Content

    private var style: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: message.sender.value,
            coloredBubbles: coloredBubbles,
            outgoingColor: outgoingBubbleColor)
    }

    private var textContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    messageBlocks(usesWhiteText: style.usesWhiteText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxHeight: isCollapsed ? Self.collapsedHeight : nil, alignment: .top)
                        .clipped()
                        .mask(collapseFade)

                    if isCollapsed {
                        Button("Show More") { isShowingFullMessage = true }
                            .buttonStyle(.plain)
                            .font(.callout.bold())
                            .foregroundStyle(style.usesWhiteText ? Color.white : Color.accentColor)
                            .padding(.top, 4)
                            .popover(isPresented: $isShowingFullMessage) {
                                fullMessagePopover
                            }
                    }
                }
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

    // MARK: - Long Message Collapse

    /// Height of the collapsed preview, in line-heights of the base font.
    private static var collapsedHeight: CGFloat { MessageTextScale.baseFontSize * 18 }

    /// Whether this text message is long enough to show only a preview.
    private var isCollapsed: Bool {
        if case .text = message.kind { return MessageBlock.isLongBody(message.body) }
        return false
    }

    /// Fades the bottom of a collapsed preview to hint that more follows.
    private var collapseFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: .black, location: isCollapsed ? 0.8 : 1),
                .init(color: isCollapsed ? .clear : .black, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    /// The whole message in a scrollable popover. It sits on the popover
    /// material rather than the bubble, so text uses the neutral colors.
    private var fullMessagePopover: some View {
        ScrollView {
            messageBlocks(usesWhiteText: false)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 520, height: 480)
        .background(.ultraThickMaterial)
        .environment(\.colorScheme, colorScheme)
    }

    private func messageBlocks(usesWhiteText: Bool) -> some View {
        MessageBlocksView(blocks: parsedBlocks, usesWhiteText: usesWhiteText) { text in
            MessageTextView(
                attributedString: text,
                isOutgoing: usesWhiteText,
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
            ImageMessageView(item: MediaItem(message: message), uploadProgress: uploadProgress)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Sticker Content

    private var stickerContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            ImageMessageView(
                item: MediaItem(message: message), uploadProgress: uploadProgress,
                isSticker: true)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Gallery Content

    private func galleryContent(body: String, items: [GalleryItem]) -> some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            GalleryMessageView(
                message: message, caption: body, items: items,
                isOutgoing: isOutgoing, uploadProgress: uploadProgress)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Video Content

    private var videoContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            VideoMessageView(item: MediaItem(message: message), uploadProgress: uploadProgress)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Audio Content

    private var audioContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            AudioMessageView(item: MediaItem(message: message),
                             senderID: message.sender.value,
                             isOutgoing: isOutgoing)
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - File Content

    private var fileContent: some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            FileMessageView(item: MediaItem(message: message),
                            senderID: message.sender.value,
                            isOutgoing: isOutgoing
            )
                .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Poll Content

    private func pollContent(_ poll: PollSummary) -> some View {
        VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            PollMessageView(
                poll: poll,
                senderID: message.sender.value,
                isOutgoing: isOutgoing,
                onVote: { actions.vote(message.eventId.value, $0) },
                onEndPoll: { actions.endPoll(message.eventId.value) }
            )
            .clipShape(BubbleStyle.shape)

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Emoji-Only Content

    /// Whether this text message contains only emoji (up to a reasonable count
    /// for large display). A present `formattedBody` still qualifies when its
    /// visible text is emoji-only (markdown sends always carry one, e.g.
    /// `<p>👋</p>`).
    private var isEmojiOnly: Bool {
        if case .text = message.kind {
            return isBigEmojiMessage(body: message.body, formattedBody: message.formattedBody)
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

            if case .failed(let reason) = message.sendState {
                sendFailedLabel(reason)
            }
        }
    }

    // MARK: - Special Content (redacted, location, poll, etc.)

    private var specialContent: some View {
        let specialStyle = BubbleStyle.special(kind: message.kind)
        return VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(message.body)
                        .font(.callout)
                } icon: {
                    Image(systemName: iconForKind)
                        .font(.callout)
                }
                if case .unableToDecrypt = message.kind,
                   let decryptionFailure
                {
                    DecryptionFailureDetails(failure: decryptionFailure)
                }
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
        case .gallery: "photo.on.rectangle.angled"
        case .location, .liveLocation: "location"
        case .sticker: "face.smiling"
        case .redacted: "trash"
        case .unableToDecrypt: "lock"
        case .state, .profileChange, .callEvent: "info.circle"
        case .unknown: "questionmark.circle"
        default: "bubble.left"
        }
    }

    // MARK: - Body Parsing (HTML -> Markdown fallback)

    /// The parsed message body as blocks. Prefers `formatted_body` (HTML) when
    /// available, falling back to Markdown parsing of `body`.
    private var parsedBlocks: [MessageBlock] {
        if let html = message.formattedBody {
            let cached = Self.htmlCache.value(forKey: Self.scaledCacheKey(html)) {
                MessageBlock.blocks(matrixHTML: html)
            }
            if !cached.isEmpty { return cached }
        }
        return Self.markdownCache.value(forKey: Self.scaledCacheKey(message.body)) {
            MessageBlock.blocks(matrixMarkdown: message.body)
        }
    }

    /// The parsed emote body as an `NSAttributedString`. Prepends an italic
    /// display name. Prefers `formatted_body` (HTML) when available.
    private var emoteParsedBody: NSAttributedString {
        if let html = message.formattedBody {
            let cacheKey = Self.scaledCacheKey("\(message.displayName)\0\(html)")
            let cached = Self.emoteHtmlCache.value(forKey: cacheKey) {
                guard let parsed = NSAttributedString(matrixHTML: html) else { return nil }
                let emoteResult = NSMutableAttributedString()
                let nameFont = MessageTextScale.baseFont
                let italicDesc = nameFont.fontDescriptor.withSymbolicTraits(.italic)
                let italicFont = NSFont(descriptor: italicDesc, size: nameFont.pointSize) ?? nameFont
                emoteResult.append(NSAttributedString(
                    string: "\(message.displayName) ",
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
            string: "\(message.displayName) ",
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

#Preview("Blocks") {
    VStack(alignment: .leading, spacing: 6) {
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "1", sender: "@alice:matrix.org", displayName: "Alice",
                body: "code",
                formattedBody: """
                <p>Try this:</p>
                <pre><code class="language-swift">let greeting = "hello"
                for index in 0..&lt;3 {
                    print(greeting, index)
                }
                let aVeryLongLine = "this line is intentionally long so that the block has to scroll horizontally instead of wrapping"
                </code></pre>
                <p>Then run it.</p>
                """
            ),
            isOutgoing: false
        )
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "2", sender: "@me:matrix.org",
                body: "table",
                formattedBody: """
                <table><thead><tr><th>Name</th><th align="right">Qty</th></tr></thead>
                <tbody><tr><td>Apple</td><td align="right">3</td></tr>
                <tr><td><b>Pear</b></td><td align="right">12</td></tr>
                <tr><td>Fig</td><td align="right">7</td></tr></tbody></table>
                """
            ),
            isOutgoing: true
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Long Message") {
    MessageBubbleContent(
        message: PreviewFixtures.event(
            "1", sender: "@alice:matrix.org", displayName: "Alice",
            body: (1...40).map { "Line \($0) of a very long message" }.joined(separator: "\n")
        ),
        isOutgoing: false
    )
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
    .environment(PreviewFixtures.previewClient())
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
        MessageBubbleContent(
            message: PreviewFixtures.event(
                "5", sender: "@bob:matrix.org", displayName: "Bob",
                body: "Lunch?",
                kind: .poll(PollSummary(
                    question: "Lunch?",
                    answers: [
                        PollSummary.Answer(id: "a1", text: "Pizza", voteCount: 2),
                        PollSummary.Answer(id: "a2", text: "Tacos", voteCount: 1),
                    ],
                    totalVotes: 3, ownSelections: ["a1"]))
            ),
            isOutgoing: false
        )
    }
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .environment(PreviewFixtures.previewClient())
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

#Preview("Gallery") {
    let items = [
        GalleryItem(
            itemtype: .image, body: "beach.jpg", filename: "beach.jpg",
            url: "mxc://matrix.org/beach",
            info: MediaInfo(mimeType: "image/jpeg", width: 800, height: 600)),
        GalleryItem(
            itemtype: .image, body: "Sunset", filename: "sunset.jpg",
            url: "mxc://matrix.org/sunset",
            info: MediaInfo(mimeType: "image/jpeg", width: 600, height: 800)),
        GalleryItem(
            itemtype: .video, body: "clip.mov", filename: "clip.mov",
            url: "mxc://matrix.org/clip",
            info: MediaInfo(mimeType: "video/quicktime", duration: 12_000)),
        GalleryItem(
            itemtype: .audio, body: "memo.m4a", filename: "memo.m4a",
            url: "mxc://matrix.org/memo",
            info: MediaInfo(mimeType: "audio/mp4", size: 120_000, duration: 34_000)),
        GalleryItem(
            itemtype: .file, body: "itinerary.pdf", filename: "itinerary.pdf",
            url: "mxc://matrix.org/itinerary",
            info: MediaInfo(mimeType: "application/pdf", size: 480_000)),
    ]
    VStack(alignment: .leading, spacing: 12) {
        ForEach([false, true], id: \.self) { isOutgoing in
            MessageBubbleContent(
                message: PreviewFixtures.event(
                    "1", sender: isOutgoing ? "@me:matrix.org" : "@alice:matrix.org",
                    body: "Trip photos",
                    kind: .gallery(body: "Trip photos", items: items)),
                isOutgoing: isOutgoing)
        }
    }
    .environment(PreviewFixtures.previewClient())
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}

#Preview("Gallery Caption Only") {
    let items = (1...3).map { number in
        GalleryItem(
            itemtype: .image, body: "photo\(number).jpg", filename: "photo\(number).jpg",
            url: "mxc://matrix.org/photo\(number)",
            info: MediaInfo(mimeType: "image/jpeg", width: 800, height: 600))
    }
    MessageBubbleContent(
        message: PreviewFixtures.event(
            "1", sender: "@me:matrix.org", body: "Are we cool yet?",
            kind: .gallery(body: "Are we cool yet?", items: items)),
        isOutgoing: true
    )
    .environment(PreviewFixtures.previewClient())
    .environment(\.timelineActions, TimelineActions(currentUserID: "@me:matrix.org"))
    .padding()
    .frame(width: 450)
}
