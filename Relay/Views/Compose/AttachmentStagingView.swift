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

import SwiftUI
import UniformTypeIdentifiers

/// A horizontal row of attachment capsules shown above the compose text field.
///
/// Each capsule displays a thumbnail or file-type icon, the filename, a remove button,
/// and an inline alt-text editing field.
struct AttachmentStagingView: View {
    @Bindable var compose: ComposeViewModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(compose.attachments) { attachment in
                    AttachmentCapsule(
                        attachment: attachment,
                        isEditingCaption: compose.editingCaptionId == attachment.id,
                        onEditCaption: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                compose.editingCaptionId = attachment.id
                            }
                        },
                        onFinishCaption: {
                            compose.editingCaptionId = nil
                        },
                        onUpdateCaption: { newValue in
                            if let index = compose.attachments.firstIndex(
                                where: { $0.id == attachment.id }
                            ) {
                                compose.attachments[index].caption = newValue
                            }
                        },
                        onRemove: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                compose.attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    )
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .scrollIndicators(.hidden)
    }
}

/// An individual attachment capsule with thumbnail, filename, caption, and remove button.
struct AttachmentCapsule: View {
    let attachment: StagedAttachment
    let isEditingCaption: Bool
    var onEditCaption: () -> Void
    var onFinishCaption: () -> Void
    var onUpdateCaption: (String) -> Void
    var onRemove: () -> Void

    @State private var captionText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                thumbnailOrIcon
                Text(attachment.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Remove attachment", systemImage: "xmark", action: onRemove)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }

            if isEditingCaption {
                TextField("Alt text", text: $captionText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .frame(maxWidth: 140)
                    .onSubmit { onFinishCaption() }
                    .onAppear { captionText = attachment.caption }
                    .onChange(of: captionText) { _, newValue in
                        onUpdateCaption(newValue)
                    }
            } else {
                Button(action: onEditCaption) {
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
        .clipShape(.rect(cornerRadius: 8))
    }

    @ViewBuilder
    private var thumbnailOrIcon: some View {
        if let thumbnail = attachment.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: ComposeViewModel.iconName(for: attachment.url))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
    }
}

#Preview {
    AttachmentStagingView(compose: {
        let vm = ComposeViewModel()
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
    }())
    .frame(width: 400)
}
