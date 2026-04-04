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

import AppKit
import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when the user selects a member from the mention suggestion list.
    /// The `userInfo` dictionary contains `"userId"` and `"displayName"` strings.
    static let insertMention = Notification.Name("relay.insertMention")
}

// MARK: - Mention Helpers

extension ComposeView {
    /// Converts resolved mentions into Matrix-format markdown for the message body.
    ///
    /// Each mention's display name is replaced with a Matrix.to permalink:
    /// `[@DisplayName](https://matrix.to/#/@user:server)` which the SDK's
    /// `messageEventContentFromMarkdown` will render into proper HTML links.
    static func markdownWithMentions(text: String, mentions: [Mention]) -> String {
        guard !mentions.isEmpty else { return text }

        // Sort mentions by range location descending so we can replace from the end
        // without invalidating earlier ranges.
        let sorted = mentions.sorted { $0.range.location > $1.range.location }
        var result = text as NSString

        for mention in sorted {
            let pillText = "@\(mention.displayName)"
            let markdownLink = "[\(pillText)](https://matrix.to/#/\(mention.userId))"
            if mention.range.location + mention.range.length <= result.length {
                result = result.replacingCharacters(in: mention.range, with: markdownLink) as NSString
            }
        }

        return result as String
    }
}

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

/// Monitors Cmd+V key events and intercepts paste when the system pasteboard
/// contains file URLs (Finder copy), raw image data, or raw video data — but
/// not plain text, which is left for the TextField to handle normally.
@Observable
final class PasteHandler {
    var pastedURLs: [URL]?
    private var monitor: Any?

    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v"
            else { return event }

            if self?.extractPastedContent() == true { return nil }
            return event
        }
    }

    func stopMonitoring() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit {
        MainActor.assumeIsolated {
            stopMonitoring()
        }
    }

    // MARK: - Extraction

    private func extractPastedContent() -> Bool {
        let pasteboard = NSPasteboard.general

        // File URLs from Finder or other file managers. Checked first because
        // Finder also puts the filename as plain text on the pasteboard.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            pastedURLs = urls
            return true
        }

        // Plain text without file URLs — let the TextField handle it.
        if pasteboard.string(forType: .string) != nil { return false }

        // Raw image data (screenshots, "Copy Image", etc.)
        if let url = extractRawImage(from: pasteboard) {
            pastedURLs = [url]
            return true
        }

        // Raw video data
        if let url = extractRawVideo(from: pasteboard) {
            pastedURLs = [url]
            return true
        }

        return false
    }

    // MARK: - Raw Image

    /// Image pasteboard types in preference order. TIFF is last because it is
    /// the generic macOS image pasteboard format and needs conversion to PNG.
    private static let imageTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (.png, ".png"),
        (NSPasteboard.PasteboardType("public.jpeg"), ".jpg"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), ".gif"),
        (NSPasteboard.PasteboardType("org.webmproject.webp"), ".webp"),
        (NSPasteboard.PasteboardType("public.heic"), ".heic"),
        (.tiff, ".png")
    ]

    private func extractRawImage(from pasteboard: NSPasteboard) -> URL? {
        for (type, ext) in Self.imageTypes {
            guard let rawData = pasteboard.data(forType: type) else { continue }

            let data: Data
            if type == .tiff {
                guard let rep = NSBitmapImageRep(data: rawData),
                      let png = rep.representation(using: .png, properties: [:])
                else { continue }
                data = png
            } else {
                data = rawData
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-Pasted Image" + ext)
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                continue
            }
        }
        return nil
    }

    // MARK: - Raw Video

    private static let videoTypes: [(type: NSPasteboard.PasteboardType, ext: String)] = [
        (NSPasteboard.PasteboardType("public.mpeg-4"), ".mp4"),
        (NSPasteboard.PasteboardType("com.apple.quicktime-movie"), ".mov"),
        (NSPasteboard.PasteboardType("public.avi"), ".avi")
    ]

    private func extractRawVideo(from pasteboard: NSPasteboard) -> URL? {
        for (type, ext) in Self.videoTypes {
            guard let data = pasteboard.data(forType: type) else { continue }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-Pasted Video" + ext)
            do {
                try data.write(to: tempURL)
                return tempURL
            } catch {
                continue
            }
        }
        return nil
    }
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

    /// The room members available for `@` mention autocomplete.
    var members: [RoomMemberDetails]

    /// Resolved mentions currently in the compose text, bound to the parent view's state
    /// so they can be read when sending the message.
    @Binding var mentions: [Mention]

    /// Called when the user submits the message (presses Return).
    var onSend: () -> Void

    /// Called when the user selects files to attach via the file picker or drag-and-drop.
    var onAttach: ([URL]) -> Void

    /// Called when the user selects a GIF from the GIF picker.
    var onGIFSelected: (GIFSearchResult) -> Void

    /// Supported UTTypes for attachments (shared by file picker and drop).
    static let supportedTypes: [UTType] = [.image, .movie, .audio, .item]

    @FocusState private var isFocused: Bool
    @State private var isShowingFilePicker = false
    @State private var isShowingGIFPicker = false
    @State private var isDropTargeted = false

    /// The ID of the attachment whose caption field is currently being edited inline.
    @State private var editingCaptionId: UUID?

    @State private var pasteHandler = PasteHandler()

    /// The active query string after `@`, or `nil` when no mention autocomplete is active.
    @State private var mentionQuery: String?

    private var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    var body: some View {
        VStack(spacing: 4) {
            mentionSuggestions

            GlassEffectContainer {
                HStack(alignment: .bottom, spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !attachments.isEmpty {
                            attachmentCapsules
                        }

                        messageField
                    }
                    .glassEffect(in: .rect(cornerRadius: !attachments.isEmpty ? 16 : 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: !attachments.isEmpty ? 18 : 22, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .padding(-4)
                            .opacity(isDropTargeted ? 1 : 0)
                    )

                    Button { isShowingFilePicker = true } label: {
                        Image(systemName: "paperclip")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                            .glassEffect(in: .circle)
                    }
                    .buttonStyle(.plain)

                    Button { isShowingGIFPicker = true } label: {
                        Image(systemName: "number")
                            .font(.system(size: 15, weight: .regular))
                            .frame(width: 32, height: 32)
                            .contentShape(Circle())
                            .glassEffect(in: .circle)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $isShowingGIFPicker, arrowEdge: .top) {
                        GIFPickerView { gif in
                            isShowingGIFPicker = false
                            onGIFSelected(gif)
                        }
                    }
                }
            }
        }
        .animation(.easeOut(duration: 0.15), value: mentionQuery != nil)
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
        .onAppear { pasteHandler.startMonitoring() }
        .onDisappear { pasteHandler.stopMonitoring() }
        .onChange(of: pasteHandler.pastedURLs) { _, urls in
            guard let urls else { return }
            pasteHandler.pastedURLs = nil
            onAttach(urls)
            isFocused = true
        }
        .onChange(of: replyingTo) {
            if replyingTo != nil { isFocused = true }
        }
    }

    // MARK: - Message Field

    private var messageField: some View {
        ComposeTextView(
            text: $text,
            mentions: $mentions,
            mentionQuery: $mentionQuery,
            onSubmit: {
                if hasContent {
                    onSend()
                }
            }
        )
    }

    // MARK: - Mention Suggestions

    @ViewBuilder
    private var mentionSuggestions: some View {
        if mentionQuery != nil {
            MentionSuggestionView(
                members: members,
                query: mentionQuery ?? "",
                onSelect: { member in
                    insertMention(member)
                },
                onDismiss: {
                    mentionQuery = nil
                }
            )
            .padding(.leading, 40)  // Aligns with the text field, past the + button (32pt) + spacing (8pt)
        }
    }

    private func insertMention(_ member: RoomMemberDetails) {
        // Find the ComposeTextView's coordinator and call insertMention
        // This is handled via the ComposeTextView's notification system
        // We post a notification that the coordinator picks up
        NotificationCenter.default.post(
            name: .insertMention,
            object: nil,
            userInfo: [
                "userId": member.userId,
                "displayName": member.displayName ?? member.userId
            ]
        )
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

}

// MARK: - Preview Data

private let previewMembers: [RoomMemberDetails] = [
    RoomMemberDetails(userId: "@alice:matrix.org", displayName: "Alice Smith", role: .administrator),
    RoomMemberDetails(userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator),
    RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis"),
    RoomMemberDetails(userId: "@diana:matrix.org", displayName: "Diana Evans")
]

#Preview("Empty") {
    ComposeView(
        text: .constant(""),
        replyingTo: .constant(nil),
        attachments: .constant([]),
        members: previewMembers,
        mentions: .constant([]),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Text") {
    ComposeView(
        text: .constant("Hello, world!"),
        replyingTo: .constant(nil),
        attachments: .constant([]),
        members: previewMembers,
        mentions: .constant([]),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Long Text") {
    // swiftlint:disable:next line_length
    let text = "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Vivamus et efficitur leo. Donec eu nunc massa. Morbi at nulla sit amet ipsum vulputate ultricies id sit amet erat. Fusce faucibus dignissim ex eget tincidunt. Donec vitae elit a tortor ultrices condimentum."
    ComposeView(
        text: .constant(text),
        replyingTo: .constant(nil),
        attachments: .constant([]),
        members: previewMembers,
        mentions: .constant([]),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
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
        members: previewMembers,
        mentions: .constant([]),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
}

#Preview("With Attachments") {
    ComposeView(
        text: .constant("Check these out"),
        replyingTo: .constant(nil),
        attachments: .constant([
            StagedAttachment(
                url: URL(fileURLWithPath: "/tmp/photo.jpg"),
                filename: "photo.jpg",
                thumbnail: nil
            ),
            StagedAttachment(
                url: URL(fileURLWithPath: "/tmp/document.pdf"),
                filename: "document.pdf",
                thumbnail: nil,
                caption: "Project brief"
            )
        ]),
        members: previewMembers,
        mentions: .constant([]),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 500)
    .environment(\.matrixService, PreviewMatrixService())
}
