import AppKit
import RelayCore
import SwiftUI
import UniformTypeIdentifiers

/// A file staged for sending, shown as a capsule in the compose bar.
///
/// Each ``StagedAttachment`` holds the local file URL (already copied to a temp directory),
/// a display-friendly filename, an optional thumbnail for images/videos, and an optional
/// user-provided caption (alt-text).
struct StagedAttachment: Identifiable {
    let id = UUID()

    /// Local file URL (temp-directory copy, security-scoped access already resolved).
    let url: URL

    /// The original filename for display.
    let filename: String

    /// A small thumbnail image for image/video attachments, or `nil` for other file types.
    let thumbnail: NSImage?

    /// User-provided alt-text / caption. Empty string means no caption.
    var caption: String = ""
}

/// The message composition bar at the bottom of the room detail view.
///
/// ``ComposeView`` includes a text field for typing messages, an attachment button for
/// sending files and images, and an inline reply banner when replying to a specific message.
/// It uses a glass-effect background for a translucent macOS-native appearance.
///
/// When files are attached via the "+" button they appear as capsules above the text field,
/// allowing the user to add a caption (alt-text) or remove them before sending.
struct ComposeView: View {
    /// The current draft message text, bound to the parent view's state.
    @Binding var text: String

    /// The message being replied to, or `nil` for a new message. Shows an inline reply banner.
    @Binding var replyingTo: TimelineMessage?

    /// Files staged for sending, displayed as removable capsules in the compose bar.
    @Binding var attachments: [StagedAttachment]

    /// Called when the user submits the message (presses Return).
    var onSend: () -> Void

    /// Called when the user selects files to attach via the file picker or drag-and-drop.
    var onAttach: ([URL]) -> Void

    /// Supported UTTypes for attachments (shared by file picker and drop).
    static let supportedTypes: [UTType] = [.image, .movie, .audio, .item]

    @FocusState private var isFocused: Bool
    @State private var isShowingFilePicker = false
    @State private var isDropTargeted = false

    /// The ID of the attachment whose caption field is currently being edited inline.
    @State private var editingCaptionId: UUID?

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                Button { isShowingFilePicker = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .regular))
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                        .glassEffect(in: .circle)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 0) {
                    if let reply = replyingTo {
                        replyBanner(reply)
                    }

                    if !attachments.isEmpty {
                        attachmentCapsules
                    }

                    messageField
                }
                .glassEffect(in: .rect(cornerRadius: (replyingTo != nil || !attachments.isEmpty) ? 16 : 20))
                .overlay(
                    RoundedRectangle(cornerRadius: (replyingTo != nil || !attachments.isEmpty) ? 18 : 22, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(-4)
                        .opacity(isDropTargeted ? 1 : 0)
                )
            }
        }
        .fileImporter(
            isPresented: $isShowingFilePicker,
            allowedContentTypes: Self.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
                isFocused = true
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            onAttach(fileURLs)
            isFocused = true
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                isDropTargeted = targeted
            }
        }
        .onChange(of: replyingTo) {
            if replyingTo != nil { isFocused = true }
        }
    }

    // MARK: - Message Field

    private var messageField: some View {
        TextField("Message", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...5)
            .focused($isFocused)
            .onSubmit {
                if hasContent {
                    onSend()
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    // MARK: - Attachment Capsules

    private var attachmentCapsules: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    attachmentCapsule(attachment)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
    }

    private func attachmentCapsule(_ attachment: StagedAttachment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                // Thumbnail or file-type icon
                if let thumbnail = attachment.thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                } else {
                    Image(systemName: iconName(for: attachment.url))
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }

                // Filename
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)

                // Remove button
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        attachments.removeAll { $0.id == attachment.id }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            // Alt-text / caption field
            if editingCaptionId == attachment.id {
                captionField(for: attachment)
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        editingCaptionId = attachment.id
                    }
                } label: {
                    Text(attachment.caption.isEmpty ? "Add alt text" : attachment.caption)
                        .font(.caption)
                        .foregroundStyle(attachment.caption.isEmpty ? .tertiary : .secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(.systemGray).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func captionField(for attachment: StagedAttachment) -> some View {
        let binding = Binding<String>(
            get: { attachments.first(where: { $0.id == attachment.id })?.caption ?? "" },
            set: { newValue in
                if let index = attachments.firstIndex(where: { $0.id == attachment.id }) {
                    attachments[index].caption = newValue
                }
            }
        )
        return TextField("Alt text", text: binding)
            .textFieldStyle(.plain)
            .font(.caption)
            .frame(maxWidth: 140)
            .onSubmit {
                editingCaptionId = nil
            }
    }

    private func iconName(for url: URL) -> String {
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        if utType.conforms(to: .image) { return "photo" }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return "film" }
        if utType.conforms(to: .audio) { return "waveform" }
        return "doc"
    }

    // MARK: - Reply Banner

    private func replyBanner(_ message: TimelineMessage) -> some View {
        HStack(alignment: .center, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.accentColor)
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(message.displayName)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(message.body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            Button {
                withAnimation(.easeOut(duration: 0.15)) { replyingTo = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.title3)
                    .frame(width: 20, height: 20)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}

#Preview("Empty") {
    ComposeView(text: .constant(""), replyingTo: .constant(nil), attachments: .constant([]), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("With Text") {
    ComposeView(text: .constant("Hello, world!"), replyingTo: .constant(nil), attachments: .constant([]), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("With Long Text") {
    ComposeView(text: .constant("Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus et efficitur leo. Donec eu nunc massa. Morbi at nulla sit amet ipsum vulputate ultricies id sit amet erat. Fusce faucibus dignissim ex eget tincidunt. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum. Donec vitae elit a tortor ultrices condimentum."), replyingTo: .constant(nil), attachments: .constant([]), onSend: {}, onAttach: { _ in })
        .frame(width: 400)
}

#Preview("Replying") {
    ComposeView(
        text: .constant(""),
        replyingTo: .constant(TimelineMessage(
            id: "1", senderID: "@alice:matrix.org", senderDisplayName: "Alice",
            body: "Nice, rooms are loading way faster now.",
            timestamp: .now, isOutgoing: false
        )),
        attachments: .constant([]),
        onSend: {},
        onAttach: { _ in }
    )
    .frame(width: 400)
}
#Preview("With Attachments") {
    ComposeView(
        text: .constant("Check these out"),
        replyingTo: .constant(nil),
        attachments: .constant([
            StagedAttachment(url: URL(fileURLWithPath: "/tmp/photo.jpg"), filename: "photo.jpg", thumbnail: nil),
            StagedAttachment(url: URL(fileURLWithPath: "/tmp/document.pdf"), filename: "document.pdf", thumbnail: nil, caption: "Project brief"),
        ]),
        onSend: {},
        onAttach: { _ in }
    )
    .frame(width: 500)
}

