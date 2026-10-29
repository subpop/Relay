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

import MatrixKit
import SwiftUI
import UniformTypeIdentifiers

/// The message composition bar at the bottom of the timeline.
///
/// ``ComposeBar`` presents the text field with inline mention pills,
/// attachment staging, reply/edit banners, and the attachment menu.
/// All compose state lives in a ``ComposeViewModel`` passed via `@Bindable`.
struct ComposeBar: View {
    @Bindable var compose: ComposeViewModel

    /// Called when the user submits a message.
    var onSend: () async -> Void

    /// Called when the user stages files (from file picker, drag, or paste).
    var onAttach: ([URL]) -> Void

    /// Called when the user selects a GIF from the picker.
    var onGIFSelected: (GIFSearchResult) async -> Void

    /// Room whose sticker packs the sticker picker offers.
    var roomId: RoomId

    /// Called when the user selects a sticker (the pack image and its shortcode).
    var onStickerSelected: (ImagePackImage, String) -> Void

    /// Called with a validated poll (question, options, max selections, kind).
    var onPollCreated: (String, [String], Int, PollKind) async -> Void

    @Environment(\.errorReporter) private var errorReporter
    @State private var pasteHandler = PasteHandler()
    @State private var mentionSuggestionsHeight: CGFloat = 0

    var body: some View {
        GlassEffectContainer {
            HStack(alignment: .bottom, spacing: 8) {
                composeContent
                actionButtons
            }
        }
        .animation(.easeOut(duration: 0.15), value: compose.mentionQuery != nil)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: compose.replyingTo != nil)
        .animation(.spring(duration: 0.35, bounce: 0.15), value: compose.editingMessage != nil)
        .fileImporter(
            isPresented: $compose.isShowingFilePicker,
            allowedContentTypes: ComposeViewModel.supportedFileTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
        .fileImporter(
            isPresented: $compose.isShowingImagePicker,
            allowedContentTypes: ComposeViewModel.supportedImageTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
        .sheet(isPresented: $compose.isShowingPollComposer) {
            PollComposerView {
                compose.isShowingPollComposer = false
            } onCreate: { question, options, maxSelections, kind in
                compose.isShowingPollComposer = false
                Task { await onPollCreated(question, options, maxSelections, kind) }
            }
        }
        .onDrop(
            of: ComposeViewModel.dropTypes,
            isTargeted: Binding(
                get: { compose.isDropTargeted },
                set: { targeted in
                    withAnimation(.easeOut(duration: 0.15)) {
                        compose.isDropTargeted = targeted
                    }
                }
            )
        ) { providers in
            guard !providers.isEmpty else { return false }
            compose.handleDropProviders(providers, errorReporter: errorReporter)
            return true
        }
        .onAppear { pasteHandler.startMonitoring() }
        .onDisappear { pasteHandler.stopMonitoring() }
        .onChange(of: pasteHandler.pastedURLs) { _, urls in
            guard let urls else { return }
            pasteHandler.pastedURLs = nil
            onAttach(urls)
        }
        .onChange(of: compose.mentionQuery) {
            compose.mentionSelectedIndex = 0
        }
    }

    // MARK: - Compose Content

    private var composeContent: some View {
        ComposeBarContent(
            compose: compose,
            mentionSuggestionsHeight: $mentionSuggestionsHeight,
            onSend: onSend
        )
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        ComposeBarActions(
            compose: compose, roomId: roomId, onGIFSelected: onGIFSelected,
            onStickerSelected: onStickerSelected)
    }
}

/// The main content area of the compose bar (text field, banners, attachments, mention suggestions).
private struct ComposeBarContent: View {
    @Bindable var compose: ComposeViewModel
    @Binding var mentionSuggestionsHeight: CGFloat
    @State private var textViewHeight: CGFloat = MessageTextScale.baseFontSize * 1.2 + 20
    var onSend: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compose.attachments.isEmpty {
                AttachmentStagingView(compose: compose)
            }

            if let replyMessage = compose.replyingTo {
                ReplyEditBanner(
                    label: "Replying to \(replyMessage.senderDisplayName ?? replyMessage.sender.value)",
                    systemImage: "arrowshape.turn.up.left"
                ) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        compose.cancelReply()
                    }
                }
            }

            if compose.editingMessage != nil {
                ReplyEditBanner(
                    label: "Editing Message",
                    systemImage: "pencil"
                ) {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        compose.cancelEdit()
                    }
                }
            }

            ComposeTextView(
                text: $compose.text,
                mentionQuery: $compose.mentionQuery,
                insertMentionHandler: $compose.insertMentionHandler,
                showEmojiPaletteHandler: $compose.showEmojiPaletteHandler,
                onSubmit: {
                    if compose.hasContent {
                        Task { await onSend() }
                    }
                },
                onCancel: compose.editingMessage != nil || compose.replyingTo != nil ? {
                    withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                        if compose.editingMessage != nil {
                            compose.cancelEdit()
                        } else {
                            compose.cancelReply()
                        }
                    }
                } : nil,
                onHeightChange: { textViewHeight = $0 },
                onMentionNavigateUp: {
                    compose.mentionSelectedIndex = max(
                        0, compose.mentionSelectedIndex - 1
                    )
                },
                onMentionNavigateDown: {
                    compose.mentionSelectedIndex += 1
                },
                onMentionConfirm: {
                    return compose.confirmSelectedMention()
                },
                shouldFocus: $compose.shouldFocusTextField
            )
            .frame(height: textViewHeight)
            .overlay(alignment: .topLeading) {
                if compose.text.isEmpty {
                    // Placeholder positioned to match textContainerInset (8, 10)
                    // plus lineFragmentPadding (4).
                    Text("Message")
                        .foregroundStyle(.placeholder)
                        .padding(.leading, 12)
                        .padding(.top, 10)
                        .allowsHitTesting(false)
                }
            }
        }
        .glassEffect(
            in: .rect(cornerRadius: !compose.attachments.isEmpty ? 16 : 20)
        )
        .overlay(
            RoundedRectangle(
                cornerRadius: !compose.attachments.isEmpty ? 18 : 22,
                style: .continuous
            )
            .strokeBorder(Color.accentColor, lineWidth: 2)
            .padding(-4)
            .opacity(compose.isDropTargeted ? 1 : 0)
        )
        .overlay(alignment: .topLeading) {
            if compose.mentionQuery != nil {
                MentionSuggestionView(compose: compose) { member in
                    compose.selectMention(member)
                }
                .padding(.horizontal, 4)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    mentionSuggestionsHeight = height
                }
                .offset(y: -(mentionSuggestionsHeight + 4))
            }
        }
    }
}

/// The plus button on the right side of the compose bar, and the popovers it opens:
/// the attachment menu, then the GIF and sticker pickers it leads to.
private struct ComposeBarActions: View {
    @Bindable var compose: ComposeViewModel
    var roomId: RoomId
    var onGIFSelected: (GIFSearchResult) async -> Void
    var onStickerSelected: (ImagePackImage, String) -> Void

    var body: some View {
        Button {
            compose.isShowingAttachmentMenu = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .regular))
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Attachments")
        .glassEffect(in: .circle)
        .popover(isPresented: $compose.isShowingAttachmentMenu, arrowEdge: .top) {
            AttachmentMenuView(compose: compose)
        }
        .popover(isPresented: $compose.isShowingGIFPicker, arrowEdge: .top) {
            GIFPickerView { gif in
                compose.isShowingGIFPicker = false
                Task { await onGIFSelected(gif) }
            }
        }
        .popover(isPresented: $compose.isShowingStickerPicker, arrowEdge: .top) {
            StickerPickerView(roomId: roomId) { image, shortcode in
                compose.isShowingStickerPicker = false
                onStickerSelected(image, shortcode)
            }
        }
    }
}

/// The attachment options shown in the compose bar's plus-button popover.
///
/// A custom popover (rather than a `Menu`) so each option renders an
/// explicit icon alongside its label.
private struct AttachmentMenuView: View {
    @Bindable var compose: ComposeViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            AttachmentMenuRow(title: "Files", systemImage: "folder") {
                compose.isShowingAttachmentMenu = false
                compose.isShowingFilePicker = true
            }
            AttachmentMenuRow(title: "Images", systemImage: "photo") {
                compose.isShowingAttachmentMenu = false
                compose.isShowingImagePicker = true
            }
            AttachmentMenuRow(title: "GIFs", systemImage: "number") {
                compose.isShowingAttachmentMenu = false
                compose.isShowingGIFPicker = true
            }
            AttachmentMenuRow(title: "Stickers", image: "custom.square.sticker") {
                compose.isShowingAttachmentMenu = false
                compose.isShowingStickerPicker = true
            }
            AttachmentMenuRow(title: "Emoji", systemImage: "face.smiling") {
                compose.isShowingAttachmentMenu = false
                compose.showEmojiPalette()
            }
            AttachmentMenuRow(title: "Poll", systemImage: "chart.bar") {
                compose.isShowingAttachmentMenu = false
                compose.isShowingPollComposer = true
            }
        }
        .padding(6)
        .frame(minWidth: 180)
    }
}

/// One icon-plus-label row in the attachment options popover.
private struct AttachmentMenuRow: View {
    var title: LocalizedStringKey
    private var icon: Image
    var action: () -> Void

    @State private var isHovering = false

    /// A row with an SF Symbol.
    init(title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) {
        self.init(title: title, icon: Image(systemName: systemImage), action: action)
    }

    /// A row with a custom symbol or image from the asset catalog.
    init(title: LocalizedStringKey, image: String, action: @escaping () -> Void) {
        self.init(title: title, icon: Image(image), action: action)
    }

    private init(title: LocalizedStringKey, icon: Image, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                icon
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(title)
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(.rect(cornerRadius: 6))
            .background(
                isHovering ? Color.primary.opacity(0.08) : .clear,
                in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Previews

private let previewMembers: [RoomMemberDetails] = [
    RoomMemberDetails(
        userId: UserId(unchecked: "@alice:matrix.org"), displayName: "Alice Smith", role: .administrator
    ),
    RoomMemberDetails(
        userId: UserId(unchecked: "@bob:matrix.org"), displayName: "Bob Chen", role: .moderator
    ),
    RoomMemberDetails(userId: UserId(unchecked: "@charlie:matrix.org"), displayName: "Charlie Davis"),
    RoomMemberDetails(userId: UserId(unchecked: "@diana:matrix.org"), displayName: "Diana Evans"),
]

private let previewRoomId = RoomId(unchecked: "!preview:matrix.org")

#Preview("Empty") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.members = previewMembers
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in },
        roomId: previewRoomId,
        onStickerSelected: { _, _ in },
        onPollCreated: { _, _, _, _ in }
    )
    .frame(width: 400)
}

#Preview("With Text") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.text = "Hello, world!"
            vm.members = previewMembers
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in },
        roomId: previewRoomId,
        onStickerSelected: { _, _ in },
        onPollCreated: { _, _, _, _ in }
    )
    .frame(width: 400)
}

#Preview("With Attachments") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.text = "Check these out"
            vm.members = previewMembers
            vm.attachments = [
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
                ),
            ]
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in },
        roomId: previewRoomId,
        onStickerSelected: { _, _ in },
        onPollCreated: { _, _, _, _ in }
    )
    .frame(width: 500)
}

#Preview("With Mention Suggestions") {
    VStack {
        Spacer()
        ComposeBar(
            compose: {
                let vm = ComposeViewModel()
                vm.text = "Hey @ali"
                vm.members = previewMembers
                vm.mentionQuery = "ali"
                return vm
            }(),
            onSend: {},
            onAttach: { _ in },
            onGIFSelected: { _ in },
            roomId: previewRoomId,
            onStickerSelected: { _, _ in },
            onPollCreated: { _, _, _, _ in }
        )
        .environment(PreviewFixtures.previewClient())
        .frame(width: 400)
    }
    .frame(height: 350)
}
