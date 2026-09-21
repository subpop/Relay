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

import AVFoundation
import MatrixKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Renders a video attachment with a thumbnail preview, play button overlay,
/// download button, and QuickLook support on double-click.
struct VideoMessageView: View {
    @Environment(RelayClient.self) private var client
    @Environment(\.mediaAutoReveal) private var autoReveal
    @Environment(\.errorReporter) private var errorReporter
    let message: ObservableTimelineEvent

    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    @State private var isHovering = false
    @State private var quickLookURL: URL?
    @State private var isLoadingMedia = false
    @State private var isRevealed = false
    @State private var cachedVideoFileURL: URL?

    private var download: MediaFileHelper.Download? {
        message.mediaDownload
    }

    private var mediaInfo: MediaInfo? {
        if case .video(_, _, let info) = message.kind { return info }
        return nil
    }

    private var displaySize: CGSize {
        mediaInfo?.displaySize(defaultHeight: 180) ?? CGSize(width: 280, height: 180)
    }

    /// Duration in seconds (`MediaInfo` carries milliseconds).
    private var durationSeconds: TimeInterval? {
        guard let ms = mediaInfo?.duration, ms > 0 else { return nil }
        return TimeInterval(ms) / 1000
    }

    private var shouldShow: Bool { autoReveal || isRevealed }

    var body: some View {
        ZStack {
            if shouldShow {
                if let thumbnail {
                    Image(nsImage: thumbnail)
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
        .overlay {
            if shouldShow, !isLoadingMedia, thumbnail != nil {
                Image(systemName: "play.fill")
                    .font(.system(size: 48, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.ultraThinMaterial)
                    .shadow(radius: 2)
                    .opacity(isHovering ? 0.8 : 0)
                    .scaleEffect(isHovering ? 1.25 : 0.85)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if shouldShow {
                HStack(spacing: 4) {
                    if let durationSeconds {
                        Text(durationSeconds.formattedDuration)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    }
                    if isHovering {
                        downloadButton
                    }
                }
                .padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if shouldShow, let caption = message.caption {
                Text(caption)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial)
                    .clipShape(.rect(cornerRadius: 8))
                    .padding(8)
            }
        }
        .onTapGesture {
            if shouldShow {
                Task { await openQuickLook() }
            }
        }
        .overlay {
            if isLoadingMedia {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay { ProgressView() }
            }
        }
        .quickLookPreview($quickLookURL)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .task(id: shouldShow ? download?.mxcURL : nil) {
            guard shouldShow, let download else { return }
            isLoading = true

            // Try server-side thumbnail first.
            if let data = await client.mediaThumbnail(
                download,
                width: UInt64(displaySize.width * 2),
                height: UInt64(displaySize.height * 2)
            ) {
                thumbnail = NSImage(data: data)
            }

            // Fall back to extracting a frame from the video locally.
            if thumbnail == nil, let data = await client.mediaBytes(download) {
                let tempURL = MediaFileHelper.temporaryFileURL(for: download)
                if (try? data.write(to: tempURL)) != nil {
                    cachedVideoFileURL = tempURL
                    let asset = AVURLAsset(url: tempURL)
                    let generator = AVAssetImageGenerator(asset: asset)
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(
                        width: displaySize.width * 2,
                        height: displaySize.height * 2
                    )
                    if let cgImage = try? await generator.image(at: .zero).image {
                        thumbnail = NSImage(cgImage: cgImage, size: .zero)
                    }
                }
            }

            isLoading = false
        }
    }

    private var downloadButton: some View {
        Button {
            Task { await saveMedia() }
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
        guard !isLoadingMedia, let download else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }

        // Resign first responder so QLPreviewPanel can find the
        // SwiftUI .quickLookPreview handler in the responder chain.
        NSApp.keyWindow?.makeFirstResponder(nil)

        if let cached = cachedVideoFileURL, FileManager.default.fileExists(atPath: cached.path) {
            quickLookURL = cached
            return
        }

        do {
            let url = try await MediaFileHelper.downloadToTemporaryFile(
                download: download, client: client
            )
            cachedVideoFileURL = url
            quickLookURL = url
        } catch {
            errorReporter.report(.mediaPreviewFailed(
                filename: download.filename,
                reason: error.localizedDescription
            ))
        }
    }

    private func saveMedia() async {
        guard let download else { return }
        let cachedData = cachedVideoFileURL.flatMap { try? Data(contentsOf: $0) }
        do {
            try await MediaFileHelper.saveToFile(
                download: download, client: client,
                contentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
                data: cachedData
            )
        } catch {
            errorReporter.report(.mediaSaveFailed(filename: download.filename, reason: error.localizedDescription))
        }
    }
}
