import QuickLook
import RelayCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Media Auto-Reveal Environment

private struct MediaAutoRevealKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var mediaAutoReveal: Bool {
        get { self[MediaAutoRevealKey.self] }
        set { self[MediaAutoRevealKey.self] = newValue }
    }
}

struct MessageView: View {
    let message: TimelineMessage
    var isLastInGroup: Bool = true
    var showSenderName: Bool = false
    var onToggleReaction: ((String) -> Void)?
    var onAddReaction: (() -> Void)?
    var onTapReply: ((String) -> Void)?
    var onReply: (() -> Void)?
    var onAvatarDoubleTap: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 2) {
            HStack(alignment: .bottom, spacing: 6) {
                if message.isOutgoing {
                    Spacer(minLength: 60)
                    replyButton
                    addReactionButton
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

                    if message.kind == .image, message.mediaInfo != nil {
                        imageContent
                    } else if message.kind == .emote {
                        emoteContent
                    } else if message.isSpecialType {
                        specialContent
                    } else {
                        textContent
                    }
                }

                if !message.isOutgoing {
                    addReactionButton
                    replyButton
                    Spacer(minLength: 60)
                }
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }

            if !message.reactions.isEmpty {
                ReactionsView(
                    reactions: message.reactions,
                    onToggle: { key in onToggleReaction?(key) }
                )
                .padding(.leading, message.isOutgoing ? 0 : 34)
            }
        }
        .padding(.vertical, message.isHighlighted ? 4 : 0)
        .padding(.horizontal, message.isHighlighted ? 6 : 0)
        .background {
            if message.isHighlighted {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(alignment: .trailing) {
                        UnevenRoundedRectangle(
                            topLeadingRadius: 0, bottomLeadingRadius: 0,
                            bottomTrailingRadius: 8, topTrailingRadius: 8
                        )
                        .fill(Color.orange)
                        .frame(width: 3)
                    }
            }
        }
    }

    // MARK: - Hover Buttons

    private var addReactionButton: some View {
        Button { onAddReaction?() } label: {
            Image(systemName: "face.smiling")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var replyButton: some View {
        Button { onReply?() } label: {
            Image(systemName: "arrowshape.turn.up.left")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .frame(width: 22, height: 22)
        .opacity(isHovering ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    // MARK: - Inline Reply

    @ViewBuilder
    private func inlineReply(_ reply: TimelineMessage.ReplyDetail, outgoing: Bool) -> some View {
        Button {
            onTapReply?(reply.eventID)
        } label: {
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(outgoing ? Color.white.opacity(0.5) : Color.accentColor)
                    .frame(width: 3, height: 28)

                VStack(alignment: .leading, spacing: 1) {
                    Text(reply.displayName)
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(outgoing ? .white.opacity(0.8) : Color.accentColor)
                        .lineLimit(1)
                    Text(reply.body)
                        .font(.caption)
                        .foregroundStyle(outgoing ? .white.opacity(0.6) : .secondary)
                        .lineLimit(2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Image Content

    private var imageContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    .background(bubbleColor)
            }
            ImageMessageView(message: message)
        }
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
    }

    // MARK: - Text Content (with markdown + links)

    private var textContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
            }
            Text(markdownBody)
                .tint(message.isOutgoing ? .white.opacity(0.9) : .accentColor)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(bubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .foregroundStyle(message.isOutgoing ? .white : .primary)
    }

    // MARK: - Emote Content

    private var emoteContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: false)
            }
            Text("*\(message.displayName)* \(markdownBody)")
                .tint(.accentColor)
                .italic()
                .textSelection(.enabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .foregroundStyle(.primary)
    }

    // MARK: - Special Content (media, redacted, encrypted, etc.)

    private var specialContent: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reply = message.replyDetail {
                inlineReply(reply, outgoing: message.isOutgoing)
            }
            Label {
                Text(message.body)
                    .font(.callout)
            } icon: {
                Image(systemName: iconForKind)
                    .font(.callout)
            }
            .foregroundStyle(foregroundForKind.opacity(0.6))
        }
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

// MARK: - Image Message View

private struct ImageMessageView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.mediaAutoReveal) private var autoReveal
    let message: TimelineMessage

    @State private var image: NSImage?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingFullImage = false
    @State private var errorMessage: String?
    @State private var isRevealed = false

    private var mediaInfo: TimelineMessage.MediaInfo {
        message.mediaInfo!
    }

    private var displaySize: CGSize {
        let maxWidth: CGFloat = 280
        let maxHeight: CGFloat = 320
        if let w = mediaInfo.width, let h = mediaInfo.height, w > 0, h > 0 {
            let aspect = CGFloat(w) / CGFloat(h)
            let width = min(CGFloat(w), maxWidth)
            let height = width / aspect
            if height > maxHeight {
                return CGSize(width: maxHeight * aspect, height: maxHeight)
            }
            return CGSize(width: width, height: height)
        }
        return CGSize(width: maxWidth, height: 200)
    }

    private var shouldShow: Bool { autoReveal || isRevealed }

    var body: some View {
        ZStack {
            if shouldShow {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: displaySize.width, height: displaySize.height)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color(.systemGray).opacity(0.15))
                        .frame(width: displaySize.width, height: displaySize.height)
                        .overlay {
                            if isLoading {
                                ProgressView()
                            } else {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            } else {
                Rectangle()
                    .fill(Color(.systemGray).opacity(0.15))
                    .frame(width: displaySize.width, height: displaySize.height)
                    .overlay {
                        VStack(spacing: 6) {
                            Image(systemName: "eye.slash")
                                .font(.title2)
                                .foregroundStyle(.secondary)
                            Text("Media Hidden")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onTapGesture { isRevealed = true }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShow, image != nil {
                downloadButton
                    .padding(8)
                    .opacity(isHovering ? 1 : 0)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if shouldShow, let caption = mediaInfo.caption, !caption.isEmpty {
                Text(caption)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
            }
        }
        .onTapGesture(count: 2) {
            if shouldShow {
                Task { await openQuickLook() }
            }
        }
        .overlay {
            if isLoadingFullImage {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .quickLookPreview($quickLookURL)
        .alert("Error", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: shouldShow ? mediaInfo.mxcURL : nil) {
            guard shouldShow else { return }
            isLoading = true
            if let data = await matrixService.mediaThumbnail(
                mxcURL: mediaInfo.mxcURL,
                width: UInt64(displaySize.width * 2),
                height: UInt64(displaySize.height * 2)
            ) {
                image = NSImage(data: data)
            }
            isLoading = false
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await saveImage() }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .black.opacity(0.5))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
    }

    private func openQuickLook() async {
        guard !isLoadingFullImage else { return }
        isLoadingFullImage = true
        defer { isLoadingFullImage = false }

        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(mediaInfo.filename)
        do {
            try data.write(to: url)
            quickLookURL = url
        } catch {
            errorMessage = "Could not preview image: \(error.localizedDescription)"
        }
    }

    private func saveImage() async {
        guard let data = await matrixService.mediaContent(mxcURL: mediaInfo.mxcURL) else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = mediaInfo.filename
        panel.allowedContentTypes = [.image]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        try? data.write(to: url)
    }
}

// MARK: - Reactions View

private struct ReactionsView: View {
    let reactions: [TimelineMessage.ReactionGroup]
    let onToggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 4) {
            ForEach(reactions) { reaction in
                Button {
                    onToggle(reaction.key)
                } label: {
                    HStack(spacing: 3) {
                        Text(reaction.key)
                            .font(.body)
                        if reaction.count > 1 {
                            Text("\(reaction.count)")
                                .font(.caption2)
                                .fontWeight(.medium)
                                .foregroundStyle(reaction.highlightedByCurrentUser ? .white : .secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        reaction.highlightedByCurrentUser
                            ? Color.accentColor.opacity(0.25)
                            : Color(.systemGray).opacity(0.12)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(
                                reaction.highlightedByCurrentUser
                                    ? Color.accentColor.opacity(0.5)
                                    : Color.clear,
                                lineWidth: 1
                            )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var height: CGFloat = 0
        var maxRowWidth: CGFloat = 0
        for (i, row) in rows.enumerated() {
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            let rowWidth = row.reduce(CGFloat(0)) { $0 + $1.sizeThatFits(.unspecified).width }
                + CGFloat(max(0, row.count - 1)) * spacing
            height += rowHeight + (i > 0 ? spacing : 0)
            maxRowWidth = max(maxRowWidth, rowWidth)
        }
        return CGSize(width: maxRowWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for (i, row) in rows.enumerated() {
            if i > 0 { y += spacing }
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for subview in row {
                let size = subview.sizeThatFits(.unspecified)
                subview.place(at: CGPoint(x: x, y: y), proposal: .init(size))
                x += size.width + spacing
            }
            y += rowHeight
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubviews.Element]] {
        let maxWidth = proposal.width ?? .infinity
        var rows: [[LayoutSubviews.Element]] = [[]]
        var currentWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentWidth + size.width + spacing > maxWidth, !rows[rows.count - 1].isEmpty {
                rows.append([])
                currentWidth = 0
            }
            rows[rows.count - 1].append(subview)
            currentWidth += size.width + spacing
        }
        return rows
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
                reactions: [.init(key: "❤️", count: 1, senderIDs: ["@me:matrix.org"], highlightedByCurrentUser: true)]
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
                    .init(key: "👍", count: 2, senderIDs: ["@alice:matrix.org", "@bob:matrix.org"], highlightedByCurrentUser: false),
                    .init(key: "❤️", count: 1, senderIDs: ["@alice:matrix.org"], highlightedByCurrentUser: false),
                    .init(key: "🎉", count: 1, senderIDs: ["@me:matrix.org"], highlightedByCurrentUser: true),
                ],
                replyDetail: .init(eventID: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice", body: "Hey, check out **this link**: https://matrix.org")
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
                replyDetail: .init(eventID: "2", senderID: "@me:matrix.org", senderDisplayName: "Me", body: "Nice — I'll take a look.")
            ),
            showSenderName: true
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
                body: "Video", timestamp: .now, isOutgoing: false, kind: .video
            ),
            showSenderName: true
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
