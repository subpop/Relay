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

import QuickLook
import RelayInterface
import SwiftUI
import UniformTypeIdentifiers

/// Renders a file attachment as a compact bubble with a system document icon,
/// filename, file size, download button on hover, and QuickLook on double-click.
struct FileMessageView: View {
    @Environment(\.matrixService) private var matrixService
    @Environment(\.errorReporter) private var errorReporter
    let message: TimelineMessage

    @State private var quickLookURL: URL?
    @State private var isLoadingMedia = false
    @State private var isHovering = false
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false

    private var mediaInfo: TimelineMessage.MediaInfo {
        message.mediaInfo!
    }

    private var style: BubbleStyle {
        .message(for: message, coloredBubbles: coloredBubbles)
    }

    /// The resolved UTType for this file, derived from the MIME type or filename extension.
    private var resolvedContentType: UTType {
        if let mime = mediaInfo.mimetype, let type = UTType(mimeType: mime) {
            return type
        }
        let ext = (mediaInfo.filename as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext) {
            return type
        }
        return .data
    }

    /// The system icon for this file type, looked up via NSWorkspace.
    private var fileIcon: NSImage {
        NSWorkspace.shared.icon(for: resolvedContentType)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: fileIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaInfo.filename)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let size = mediaInfo.size, size > 0 {
                    Text(formatFileSize(size))
                        .font(.caption)
                        .foregroundStyle(style.usesWhiteText ? .white.opacity(0.7) : .secondary)
                }
            }

            Spacer(minLength: 0)

            if isHovering {
                downloadButton
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: 200, maxWidth: 300)
        .background(style.backgroundColor)
        .foregroundStyle(style.usesWhiteText ? .white : .primary)
        .onTapGesture(count: 2) {
            Task { await openQuickLook() }
        }
        .overlay {
            if isLoadingMedia {
                BubbleStyle.shape
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .quickLookPreview($quickLookURL)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    private var downloadButton: some View {
        Button {
            Task { await saveMedia() }
        } label: {
            Image(systemName: "arrow.down.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(
                    style.usesWhiteText ? .white : .primary,
                    style.usesWhiteText ? .white.opacity(0.25) : Color(.systemGray).opacity(0.2)
                )
        }
        .buttonStyle(.plain)
    }

    private func openQuickLook() async {
        guard !isLoadingMedia else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        // Resign first responder so QLPreviewPanel can find the
        // SwiftUI .quickLookPreview handler in the responder chain.
        NSApp.keyWindow?.makeFirstResponder(nil)

        do {
            quickLookURL = try await MediaFileHelper.downloadToTemporaryFile(
                mediaInfo: mediaInfo, matrixService: matrixService
            )
        } catch {
            errorReporter.report(.mediaPreviewFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
        }
    }

    private func saveMedia() async {
        do {
            try await MediaFileHelper.saveToFile(
                mediaInfo: mediaInfo, matrixService: matrixService,
                contentTypes: [resolvedContentType]
            )
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: mediaInfo.filename, reason: error.localizedDescription))
        }
    }

    private func formatFileSize(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
