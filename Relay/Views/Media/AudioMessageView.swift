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
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Renders an audio attachment as a compact bubble with waveform icon, filename,
/// duration, download button, and QuickLook support on double-click.
struct AudioMessageView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.errorReporter) private var errorReporter
    @AppStorage("appearance.coloredBubbles") private var coloredBubbles = false

    let message: ObservableTimelineEvent

    /// Whether the message was sent by the local user.
    let isOutgoing: Bool

    @State private var quickLookURL: URL?
    @State private var isLoadingMedia = false
    @State private var isHovering = false

    private var download: MediaFileHelper.Download? {
        message.mediaDownload
    }

    private var mediaInfo: MediaInfo? {
        if case .audio(_, _, let info) = message.kind { return info }
        return nil
    }

    /// Duration in seconds (`MediaInfo` carries milliseconds).
    private var durationSeconds: TimeInterval? {
        guard let ms = mediaInfo?.duration, ms > 0 else { return nil }
        return TimeInterval(ms) / 1000
    }

    private var style: BubbleStyle {
        .message(
            isOutgoing: isOutgoing,
            senderID: message.sender.value,
            coloredBubbles: coloredBubbles)
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(style.usesWhiteText ? Color.white.opacity(0.2) : Color.accentColor.opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "waveform")
                    .font(.body)
                    .fontWeight(.medium)
                    .foregroundStyle(style.usesWhiteText ? .white : .accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(download?.filename ?? message.body)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    if let durationSeconds {
                        Text(durationSeconds.formattedDuration)
                            .font(.caption)
                    }
                    if let size = download?.size, size > 0 {
                        if durationSeconds != nil {
                            Text("·")
                                .font(.caption)
                        }
                        Text(formatFileSize(size))
                            .font(.caption)
                    }
                }
                .foregroundStyle(style.usesWhiteText ? .white.opacity(0.7) : .secondary)
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
        guard !isLoadingMedia, let download else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        // Resign first responder so QLPreviewPanel can find the
        // SwiftUI .quickLookPreview handler in the responder chain.
        NSApp.keyWindow?.makeFirstResponder(nil)

        do {
            quickLookURL = try await MediaFileHelper.downloadToTemporaryFile(
                download: download, client: client
            )
        } catch {
            errorReporter.report(.mediaPreviewFailed(filename: download.filename, reason: error.localizedDescription))
        }
    }

    private func saveMedia() async {
        guard let download else { return }
        do {
            try await MediaFileHelper.saveToFile(
                download: download, client: client,
                contentTypes: [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
            )
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: download.filename, reason: error.localizedDescription))
        }
    }

    private func formatFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
