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

/// A horizontal row of attachment thumbnails shown above the compose text field.
///
/// Each thumbnail displays a preview image or file-type icon with an overlaid remove
/// button. Image attachments include an inline alt-text editing field below the thumbnail.
struct AttachmentStagingView: View {
    @Bindable var compose: ComposeViewModel

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 10) {
                ForEach(compose.attachments) { attachment in
                    AttachmentThumbnail(
                        attachment: attachment,
                        isOversized: compose.isOversized(attachment),
                        maxUploadSize: compose.maxUploadSize,
                        isPublishing: compose.publishingAttachmentId == attachment.id,
                        onCancelPublish: compose.cancelICloudLink,
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
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)

        Divider()
            .padding(.horizontal, 14)
    }
}

/// An individual attachment thumbnail with an overlaid remove button.
///
/// Image attachments display an aspect-ratio-preserving preview with an alt-text
/// field below. Non-image attachments display a large file-type icon with the
/// filename underneath, similar to a Finder icon view.
struct AttachmentThumbnail: View {
    let attachment: StagedAttachment
    var isOversized = false
    var maxUploadSize: Int?
    var isPublishing = false
    var onCancelPublish: () -> Void = {}
    let isEditingCaption: Bool
    var onEditCaption: () -> Void
    var onFinishCaption: () -> Void
    var onUpdateCaption: (String) -> Void
    var onRemove: () -> Void

    @State private var captionText = ""

    private var isImage: Bool { attachment.thumbnail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailContent
                    .overlay { UploadingOverlay(isPublishing: isPublishing, onCancel: onCancelPublish) }
                    .overlay(alignment: .bottomTrailing) {
                        if isOversized, !isPublishing {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .symbolRenderingMode(.multicolor)
                                .padding(4)
                                .help(oversizedHelp)
                        }
                    }

                Button("Remove", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .imageScale(.large)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .offset(x: 6, y: -6)
            }

            if isImage {
                captionArea
            }
        }
        .fixedSize()
    }

    private var oversizedHelp: String {
        guard let maxUploadSize else { return "" }
        let limit = Int64(maxUploadSize).formatted(.byteCount(style: .file))
        return String(
            localized: "This file is larger than the server's \(limit) upload limit.",
            comment: "Tooltip on a staged attachment that exceeds the homeserver's upload size limit")
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let thumbnail = attachment.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(thumbnail.size, contentMode: .fit)
                .frame(maxWidth: 80, maxHeight: 80)
                .clipShape(.rect(cornerRadius: 8))
        } else {
            VStack(spacing: 4) {
                Image(systemName: ComposeViewModel.iconName(for: attachment.url))
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(attachment.filename)
                    .font(.caption2)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 80, height: 80)
            .background(.quaternary, in: .rect(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private var captionArea: some View {
        if isEditingCaption {
            TextField("Alt text", text: $captionText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption)
                .lineLimit(1...4)
                .onSubmit { onFinishCaption() }
                .onAppear { captionText = attachment.caption }
                .onChange(of: captionText) { _, newValue in
                    onUpdateCaption(newValue)
                }
        } else {
            Button(action: onEditCaption) {
                Text(attachment.caption.isEmpty ? "Alt text" : attachment.caption)
                    .font(.caption)
                    .foregroundStyle(attachment.caption.isEmpty ? .tertiary : .secondary)
                    .lineLimit(1...2)
            }
            .buttonStyle(.plain)
        }
    }
}

/// A progress overlay shown on an attachment while it uploads to iCloud.
private struct UploadingOverlay: View {
    let isPublishing: Bool
    var onCancel: () -> Void

    var body: some View {
        if isPublishing {
            VStack(spacing: 4) {
                ProgressView()
                    .controlSize(.small)
                Text("Uploading to iCloud…")
                    .font(.caption2)
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
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
