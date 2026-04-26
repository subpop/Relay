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
import UniformTypeIdentifiers

/// The message composition bar at the bottom of the timeline.
///
/// ``ComposeBar`` presents the text field with inline mention pills,
/// attachment staging, reply/edit banners, and action buttons (attach, GIF).
/// All compose state lives in a ``ComposeViewModel`` passed via `@Bindable`.
struct ComposeBar: View {
    @Bindable var compose: ComposeViewModel

    /// Called when the user submits a message.
    var onSend: () async -> Void

    /// Called when the user stages files (from file picker, drag, or paste).
    var onAttach: ([URL]) -> Void

    /// Called when the user selects a GIF from the picker.
    var onGIFSelected: (GIFSearchResult) async -> Void

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
            allowedContentTypes: ComposeViewModel.supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result, !urls.isEmpty {
                onAttach(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let fileURLs = urls.filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return false }
            onAttach(fileURLs)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) {
                compose.isDropTargeted = targeted
            }
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
        ComposeBarActions(compose: compose, onGIFSelected: onGIFSelected)
    }
}

/// The main content area of the compose bar (text field, banners, attachments, mention suggestions).
private struct ComposeBarContent: View {
    @Bindable var compose: ComposeViewModel
    @Binding var mentionSuggestionsHeight: CGFloat
    @State private var textViewHeight: CGFloat = NSFont.systemFontSize * 1.2 + 20
    var onSend: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compose.attachments.isEmpty {
                AttachmentStagingView(compose: compose)
            }

            if let replyMessage = compose.replyingTo {
                ReplyEditBanner(
                    label: "Replying to \(replyMessage.senderDisplayName ?? replyMessage.senderID)",
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
                onSubmit: {
                    if compose.hasContent {
                        Task { await onSend() }
                    }
                },
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
                    compose.confirmSelectedMention()
                }
            )
            .frame(height: textViewHeight)
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

/// The attach and GIF buttons on the right side of the compose bar.
private struct ComposeBarActions: View {
    @Bindable var compose: ComposeViewModel
    var onGIFSelected: (GIFSearchResult) async -> Void

    var body: some View {
        Button("Attach file", systemImage: "paperclip") {
            compose.isShowingFilePicker = true
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .regular))
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .glassEffect(in: .circle)
        .buttonStyle(.plain)

        Button("GIF picker", systemImage: "number") {
            compose.isShowingGIFPicker = true
        }
        .labelStyle(.iconOnly)
        .font(.system(size: 15, weight: .regular))
        .frame(width: 32, height: 32)
        .contentShape(Circle())
        .glassEffect(in: .circle)
        .buttonStyle(.plain)
        .popover(isPresented: $compose.isShowingGIFPicker, arrowEdge: .top) {
            GIFPickerView { gif in
                compose.isShowingGIFPicker = false
                Task { await onGIFSelected(gif) }
            }
        }
    }
}

// MARK: - Previews

private let previewMembers: [RoomMemberDetails] = [
    RoomMemberDetails(
        userId: "@alice:matrix.org", displayName: "Alice Smith", role: .administrator
    ),
    RoomMemberDetails(
        userId: "@bob:matrix.org", displayName: "Bob Chen", role: .moderator
    ),
    RoomMemberDetails(userId: "@charlie:matrix.org", displayName: "Charlie Davis"),
    RoomMemberDetails(userId: "@diana:matrix.org", displayName: "Diana Evans"),
]

#Preview("Empty") {
    ComposeBar(
        compose: {
            let vm = ComposeViewModel()
            vm.members = previewMembers
            return vm
        }(),
        onSend: {},
        onAttach: { _ in },
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
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
        onGIFSelected: { _ in }
    )
    .frame(width: 400)
    .environment(\.matrixService, PreviewMatrixService())
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
        onGIFSelected: { _ in }
    )
    .frame(width: 500)
    .environment(\.matrixService, PreviewMatrixService())
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
            onGIFSelected: { _ in }
        )
        .frame(width: 400)
    }
    .frame(height: 350)
    .environment(\.matrixService, PreviewMatrixService())
}
