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
import OSLog
import RelayInterface
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "Relay", category: "ComposeViewModel")

/// Owns all state and logic for the message compose bar.
///
/// ``ComposeViewModel`` consolidates draft text, reply/edit context,
/// staged attachments, and mention tracking into a single `@Observable`
/// object. Views bind to it via `@State` (owner) or `@Bindable` (children).
@Observable
final class ComposeViewModel {

    // MARK: - Draft State

    /// The current draft message text (plain text with user IDs for pills).
    var text = ""

    /// The message being replied to, if any.
    var replyingTo: TimelineMessage?

    /// The message being edited, if any.
    var editingMessage: TimelineMessage?

    /// Files staged for sending (shown as capsules in the compose bar).
    var attachments: [StagedAttachment] = []

    /// Resolved user mentions tracked alongside the draft.
    var mentions: [Mention] = []

    // MARK: - Mention Autocomplete

    /// The active `@`-query string, or `nil` when autocomplete is inactive.
    var mentionQuery: String?

    /// The highlighted row index in the mention suggestion list.
    var mentionSelectedIndex = 0

    /// Room members available for `@` mention autocomplete.
    var members: [RoomMemberDetails] = []

    // MARK: - UI State

    /// Whether the file picker sheet is presented.
    var isShowingFilePicker = false

    /// Whether the GIF picker popover is presented.
    var isShowingGIFPicker = false

    /// Whether a drag operation is currently hovering over the compose bar.
    var isDropTargeted = false

    /// The ID of the attachment whose caption field is being edited inline.
    var editingCaptionId: UUID?

    // MARK: - Text View Bridge

    /// Closure set by ``ComposeBar`` to insert a mention pill into the text view.
    /// Called by ``selectMention(_:)`` to bridge from the view model to the
    /// `ComposeTextView.Coordinator`.
    var insertMentionHandler: ((_ userId: String, _ displayName: String) -> Void)?

    // MARK: - Supported Types

    /// UTTypes accepted by the file picker and drop target.
    static let supportedTypes: [UTType] = [.image, .movie, .audio, .item]

    // MARK: - Computed Properties

    /// Whether the compose bar has any sendable content.
    var hasContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// The filtered member list matching the current mention query.
    var filteredMentionMembers: [RoomMemberDetails] {
        let query = mentionQuery ?? ""
        if query.isEmpty {
            return Array(members.prefix(12))
        }
        return members.filter { member in
            let name = member.displayName ?? member.userId
            return name.localizedStandardContains(query)
                || member.userId.localizedStandardContains(query)
        }
    }

    // MARK: - Mention Actions

    /// Confirms the currently highlighted mention suggestion.
    ///
    /// Returns `true` if a suggestion was selected, or `false` when the
    /// suggestion list was empty (no match to confirm).  When returning
    /// `false`, `mentionQuery` is cleared so the caller can fall through
    /// to normal Return-to-send behaviour.
    @discardableResult
    func confirmSelectedMention() -> Bool {
        let matches = filteredMentionMembers
        guard !matches.isEmpty else {
            mentionQuery = nil
            return false
        }
        let index = max(0, min(mentionSelectedIndex, matches.count - 1))
        selectMention(matches[index])
        return true
    }

    /// Inserts a mention pill for the given member via the text view coordinator.
    ///
    /// Calls the ``insertMentionHandler`` closure (set by ``ComposeBar``)
    /// which bridges into the `ComposeTextView.Coordinator.insertMention()` method.
    /// Also appends a ``Mention`` record for serialization at send time.
    func selectMention(_ member: RoomMemberDetails) {
        let displayName = member.displayName ?? member.userId
        insertMentionHandler?(member.userId, displayName)
        mentions.append(Mention(userId: member.userId, displayName: displayName))
        mentionQuery = nil
        mentionSelectedIndex = 0
    }

    /// Removes a previously inserted mention.
    func removeMention(_ mention: Mention) {
        mentions.removeAll { $0.id == mention.id }
    }

    // MARK: - Reply / Edit

    /// Cancels the current reply.
    func cancelReply() {
        replyingTo = nil
    }

    /// Cancels the current edit, restoring the draft to empty.
    func cancelEdit() {
        editingMessage = nil
        text = ""
        mentions = []
    }

    // MARK: - Send

    /// Sends the current draft (text + attachments), handling edit vs. new message.
    ///
    /// - Parameters:
    ///   - viewModel: The timeline view model to send through.
    ///   - matrixService: The Matrix service for typing notices.
    ///   - roomId: The room to send in.
    ///   - sendTypingNotifications: Whether typing notices are enabled.
    ///   - onScrollToBottom: Called when a new message is sent (not an edit).
    func send(
        using viewModel: any TimelineViewModelProtocol,
        matrixService: any MatrixServiceProtocol,
        roomId: String,
        sendTypingNotifications: Bool,
        onScrollToBottom: (() -> Void)? = nil
    ) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingAttachments = attachments
        guard !trimmedText.isEmpty || !pendingAttachments.isEmpty else { return }

        let mentionedUserIds = mentions.map(\.userId)
        let messageText = markdownWithMentions().trimmingCharacters(in: .whitespacesAndNewlines)

        if let editing = editingMessage {
            let editId = editing.id
            text = ""
            mentions = []
            editingMessage = nil
            Task {
                if sendTypingNotifications {
                    await matrixService.sendTypingNotice(roomId: roomId, isTyping: false)
                }
                await viewModel.edit(
                    messageId: editId, newText: messageText, mentionedUserIds: mentionedUserIds
                )
            }
            return
        }

        let replyEventId = replyingTo?.id
        text = ""
        mentions = []
        replyingTo = nil
        attachments = []
        onScrollToBottom?()
        Task {
            if sendTypingNotifications {
                await matrixService.sendTypingNotice(roomId: roomId, isTyping: false)
            }
            if !messageText.isEmpty {
                await viewModel.send(
                    text: messageText, inReplyTo: replyEventId, mentionedUserIds: mentionedUserIds
                )
            }
            for attachment in pendingAttachments {
                let caption = attachment.caption.trimmingCharacters(in: .whitespacesAndNewlines)
                await viewModel.sendAttachment(
                    url: attachment.url, caption: caption.isEmpty ? nil : caption
                )
            }
        }
    }

    // MARK: - Attachments

    /// Stages selected files as ``StagedAttachment`` capsules in the compose bar.
    ///
    /// Files are copied to a temp directory so security-scoped bookmarks can be
    /// released immediately. Already-temp files (e.g. from paste) are used directly.
    func stageAttachments(_ urls: [URL], errorReporter: ErrorReporter) {
        let tempDir = FileManager.default.temporaryDirectory
        for url in urls {
            let didAccessScope = url.startAccessingSecurityScopedResource()
            defer { if didAccessScope { url.stopAccessingSecurityScopedResource() } }

            if url.path().hasPrefix(tempDir.path()) {
                let thumbnail = generateThumbnail(for: url)
                let staged = StagedAttachment(
                    url: url, filename: url.lastPathComponent, thumbnail: thumbnail
                )
                attachments.append(staged)
                continue
            }

            let dest = tempDir.appending(
                path: UUID().uuidString + "-" + url.lastPathComponent
            )
            do {
                try FileManager.default.copyItem(at: url, to: dest)
            } catch {
                logger.error("Failed to copy file \(url.lastPathComponent): \(error)")
                errorReporter.report(
                    .fileCopyFailed(
                        filename: url.lastPathComponent, reason: error.localizedDescription
                    )
                )
                continue
            }

            let thumbnail = generateThumbnail(for: dest)
            let staged = StagedAttachment(
                url: dest, filename: url.lastPathComponent, thumbnail: thumbnail
            )
            attachments.append(staged)
        }
    }

    /// Downloads and sends a GIF via the attachment pipeline.
    func sendGIF(
        _ gif: GIFSearchResult,
        using viewModel: any TimelineViewModelProtocol,
        gifSearchService: any GIFSearchServiceProtocol,
        errorReporter: ErrorReporter,
        onScrollToBottom: (() -> Void)? = nil
    ) {
        onScrollToBottom?()
        Task {
            if let url = gif.onsentURL {
                await gifSearchService.registerAction(url: url)
            }

            let data: Data
            do {
                data = try await gifSearchService.downloadGIF(url: gif.originalURL)
            } catch {
                errorReporter.report(
                    .fileCopyFailed(filename: "GIF", reason: error.localizedDescription)
                )
                return
            }

            let filename = "\(gif.id).gif"
            let tempURL = FileManager.default.temporaryDirectory.appending(path: filename)
            do {
                try data.write(to: tempURL)
            } catch {
                errorReporter.report(
                    .fileCopyFailed(filename: filename, reason: error.localizedDescription)
                )
                return
            }

            await viewModel.sendAttachment(url: tempURL, caption: nil)
        }
    }

    // MARK: - Drop Handling

    /// UTTypes accepted for drag-and-drop into the compose bar or timeline.
    ///
    /// Covers file URLs, file promises, and raw image data so that screenshots
    /// dragged from the macOS floating preview are accepted alongside Finder files.
    static let dropTypes: [UTType] = [.fileURL, .image]

    /// Processes drop providers, handling both file URLs and raw image data.
    ///
    /// File URLs are staged directly. For raw image data (e.g. a screenshot
    /// dragged from the macOS floating preview), the data is written to a temp
    /// file before staging. This mirrors the behaviour of ``PasteHandler``.
    func handleDropProviders(
        _ providers: [NSItemProvider],
        errorReporter: ErrorReporter
    ) {
        for provider in providers {
            // Prefer file URL — covers Finder drags and saved files.
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier
                ) { data, error in
                    guard let data = data as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                    else {
                        if let error {
                            logger.error("Error loading URL: \(error.localizedDescription)")
                        }
                        return
                    }
                    Task { @MainActor in
                        self.stageAttachments([url], errorReporter: errorReporter)
                    }
                }
                continue
            }

            // Fall back to raw image data (screenshots, "Copy Image" drags).
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                loadDroppedImage(from: provider, errorReporter: errorReporter)
                continue
            }
        }
    }

    /// Loads raw image data from an `NSItemProvider` and stages it as an attachment.
    ///
    /// Tries concrete image formats in preference order before falling back to
    /// TIFF (macOS's generic image pasteboard type), which is converted to PNG.
    private func loadDroppedImage(
        from provider: NSItemProvider,
        errorReporter: ErrorReporter
    ) {
        // Concrete types in preference order; TIFF last because it needs conversion.
        let imageTypes: [(type: UTType, ext: String)] = [
            (.png, ".png"),
            (.jpeg, ".jpg"),
            (.gif, ".gif"),
            (.webP, ".webp"),
            (.heic, ".heic"),
            (.tiff, ".png"),
        ]

        // Find the first concrete type the provider can supply.
        guard let match = imageTypes.first(where: {
            provider.hasItemConformingToTypeIdentifier($0.type.identifier)
        }) else { return }

        provider.loadDataRepresentation(
            forTypeIdentifier: match.type.identifier
        ) { data, error in
            guard let rawData = data else {
                if let error {
                    logger.error("Error loading dropped image: \(error.localizedDescription)")
                }
                return
            }

            let fileData: Data
            if match.type == .tiff {
                guard let rep = NSBitmapImageRep(data: rawData),
                      let png = rep.representation(using: .png, properties: [:])
                else { return }
                fileData = png
            } else {
                fileData = rawData
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString + "-Dropped Image" + match.ext)
            do {
                try fileData.write(to: tempURL)
            } catch {
                logger.error("Failed to write dropped image to temp file: \(error)")
                return
            }

            Task { @MainActor in
                let thumbnail = self.generateThumbnail(for: tempURL)
                let staged = StagedAttachment(
                    url: tempURL,
                    filename: tempURL.lastPathComponent,
                    thumbnail: thumbnail
                )
                self.attachments.append(staged)
            }
        }
    }

    // MARK: - Private Helpers

    /// Generates a small thumbnail for image files, or `nil` for other types.
    private func generateThumbnail(for url: URL) -> NSImage? {
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        guard utType.conforms(to: .image) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let maxDimension: CGFloat = 56
        let size = image.size
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1.0)
        let targetSize = NSSize(width: size.width * scale, height: size.height * scale)
        return NSImage(size: targetSize, flipped: false) { rect in
            image.draw(in: rect)
            return true
        }
    }

    /// Converts the draft text + mentions into markdown with Matrix.to links.
    ///
    /// Scans the text for each mention's user ID and replaces occurrences with
    /// a Matrix.to markdown link: `[DisplayName](https://matrix.to/#/@user:server)`.
    func markdownWithMentions() -> String {
        var result = text
        for mention in mentions {
            let link = "[\(mention.displayName)](https://matrix.to/#/\(mention.userId))"
            result = result.replacing(mention.userId, with: link)
        }
        return result
    }

    /// Returns the SF Symbol name for a file's UTType.
    static func iconName(for url: URL) -> String {
        let utType = UTType(filenameExtension: url.pathExtension) ?? .data
        if utType.conforms(to: .image) { return "photo" }
        if utType.conforms(to: .movie) || utType.conforms(to: .video) { return "film" }
        if utType.conforms(to: .audio) { return "waveform" }
        return "doc"
    }
}
