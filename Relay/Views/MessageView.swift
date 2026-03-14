import RelayCore
import SwiftUI

struct MessageView: View {
    let message: TimelineMessage
    var isLastInGroup: Bool = true
    var showSenderName: Bool = false

    var body: some View {
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

                if message.kind == .emote {
                    emoteContent
                } else if message.isSpecialType {
                    specialContent
                } else {
                    textContent
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - Text Content (with markdown + links)

    private var textContent: some View {
        Text(markdownBody)
            .tint(message.isOutgoing ? .white.opacity(0.9) : .accentColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(bubbleColor)
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .foregroundStyle(message.isOutgoing ? .white : .primary)
            .textSelection(.enabled)
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        Text("*\(message.displayName)* \(markdownBody)")
            .tint(.accentColor)
            .italic()
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.purple.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
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

    private var styleForKind: HierarchicalShapeStyle {
        .secondary
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

    // MARK: - Markdown Parsing

    private var markdownBody: AttributedString {
        let raw = message.body
        if let md = try? AttributedString(markdown: raw, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return md
        }
        return AttributedString(raw)
    }

    // MARK: - Bubble Color

    private var bubbleColor: Color {
        message.isOutgoing ? .accentColor : Color(.systemGray).opacity(0.2)
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
                isOutgoing: false
            )
        )
        MessageView(
            message: TimelineMessage(
                id: "2",
                senderID: "@me:matrix.org",
                body: "Nice — I'll take a look.",
                timestamp: .now.addingTimeInterval(-60),
                isOutgoing: true
            )
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
                id: "i1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Image", timestamp: .now, isOutgoing: false, kind: .image
            ),
            showSenderName: true
        )
        MessageView(
            message: TimelineMessage(
                id: "v1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
                body: "Video", timestamp: .now, isOutgoing: false, kind: .video
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
